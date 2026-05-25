/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · api/_middleware.js
   Edge middleware: subdomain → tenant resolution + URL rewriting +
   tenant dataset injection.

   This file is the brain of multi-tenancy. Every request to the platform
   passes through it once (unless excluded by the matcher below). The
   middleware itself lives in /middleware.js at the project root — that
   file is a one-line re-export Vercel scans for; the logic lives here so
   the architectural map in README.md is honest.

   Per request, in order:

     1. Skip — static assets, /api/, /css/, /js/, /lib/, /Brand/, /_vercel/
        (the matcher excludes most; the body re-checks defensively).

     2. Brand book — /brandbook → /Brand/brandbook.html (apex OR tenant).

     3. Host parse — extract slug, classify as apex vs tenant subdomain.

     4. Apex (theunionhub.com) — rewrite /<path> → /app/<path>.html.
        No tenant data needed; marketing site is tenant-agnostic.

     5. Tenant subdomain (local183.theunionhub.com):
          a. Look up the tenant row in Supabase
             (edge cache → REST fetch, fail-open on errors).
          b. status='active'   → rewrite to /tenants/_template/<path>.html
                                  + inject x-tenant-{id,slug,name,accent,status}
                                  headers so the page can render w/o another fetch.
          c. status='archived' → rewrite to /410.html, set status code 410.
          d. not found         → rewrite to /404.html, set status code 404.
          e. Supabase down     → fail open: proceed with slug-only routing
                                  (page-level fetch will surface the real error).

   Tenant existence is checked here, NOT enforced. Row Level Security on
   Supabase is the actual security boundary. The middleware is a UX layer:
   it returns the right page for the right state and saves the page one
   round-trip when things are healthy.
   ────────────────────────────────────────────────────────────────────────── */

import { next, rewrite } from '@vercel/edge';

export const config = {
  matcher: '/((?!api/|_vercel/|css/|lib/|Brand/|.*\\.[a-zA-Z0-9]+$).*)',
};

/* ─── Constants ───────────────────────────────────────────────────────── */

/* Slugs that must never resolve to a tenant. Mirror of the CHECK
   constraint on tenants.slug — keep these two in sync (and update
   tenants/README.md too). */
const RESERVED_SLUGS = new Set([
  'www', 'app', 'api', 'admin', 'status', 'docs', 'blog',
  'mail', 'assets', 'cdn', 'static', 'demo-www',
]);

/* Pages that live under /tenants/_template. Anything else falls through
   to a 404 via Vercel's normal handling. */
const TENANT_PAGES = new Set(['card', 'verify', 'index']);

/* Edge worker-level cache. Survives across requests on the same instance
   for ~30 minutes (Vercel's edge worker lifecycle). On cache miss we hit
   Supabase. Replace with @vercel/edge-config or KV once the tenants table
   is hot enough that 60s staleness is unacceptable. */
const tenantCache = new Map(); // slug → { data, expiresAt }
const TENANT_CACHE_TTL_MS = 60_000;
const NEGATIVE_CACHE_TTL_MS = 30_000; // cache "not found" half as long

/* Status codes for explicit error rewrites. We rewrite to a static HTML
   page AND set the HTTP status so crawlers and clients see the right
   semantic answer (not a soft 200). */
const HTTP_GONE = 410;
const HTTP_NOT_FOUND = 404;


/* ─── Pure helpers ────────────────────────────────────────────────────── */

function parseHost(host, apex) {
  if (!host) return { slug: null, isApex: true };
  const bare = host.split(':')[0].toLowerCase();

  if (bare === apex) return { slug: null, isApex: true };
  if (bare.endsWith('.' + apex)) {
    const slug = bare.slice(0, -(apex.length + 1));
    if (RESERVED_SLUGS.has(slug)) return { slug: null, isApex: true };
    return { slug, isApex: false };
  }

  /* Fallback for unknown hosts (preview deployments, lvh.me, etc.):
     first label is the tentative slug. */
  const parts = bare.split('.');
  if (parts.length >= 2) {
    const slug = parts[0];
    if (RESERVED_SLUGS.has(slug)) return { slug: null, isApex: true };
    return { slug, isApex: false };
  }
  return { slug: null, isApex: true };
}

function normalisePath(pathname) {
  const stripped = pathname.replace(/^\/+|\/+$/g, '');
  return stripped || 'index';
}

function isStaticOrInternal(pathname) {
  return (
    pathname.startsWith('/api/')   ||
    pathname.startsWith('/_vercel/') ||
    pathname.startsWith('/css/')   ||
    pathname.startsWith('/lib/')   ||
    pathname.startsWith('/Brand/') ||
    /\.[a-zA-Z0-9]+$/.test(pathname)
  );
}

function getEnv() {
  if (typeof process !== 'undefined' && process.env) return process.env;
  if (typeof globalThis !== 'undefined' && globalThis.process && globalThis.process.env) {
    return globalThis.process.env;
  }
  return {};
}


/* ─── Tenant resolution ───────────────────────────────────────────────── */

/**
 * Resolve a tenant slug to its full row.
 *
 * Returns:
 *   { id, slug, display_name, accent_hex, status }   on success
 *   { status: 'not_found' }                          when no row exists
 *   { status: 'error', reason: '…' }                 on transport failure (fail-open)
 *
 * The "error" path lets the caller decide whether to fail the request
 * or proceed without tenant injection. Default policy: proceed.
 */
async function resolveTenant(slug, env) {
  if (!slug) return { status: 'not_found' };

  /* Cache check */
  const cached = tenantCache.get(slug);
  if (cached && cached.expiresAt > Date.now()) return cached.data;

  const supabaseUrl = env.SUPABASE_URL;
  const anonKey     = env.SUPABASE_ANON_KEY;

  /* If Supabase isn't wired up yet (e.g. very early in scaffold), don't
     blow up — return a sentinel so the caller falls through to slug-only. */
  if (!supabaseUrl || !anonKey) {
    return { status: 'error', reason: 'supabase_unconfigured' };
  }

  try {
    const url = `${supabaseUrl.replace(/\/+$/, '')}/rest/v1/tenants`
      + `?slug=eq.${encodeURIComponent(slug)}`
      + `&select=id,slug,display_name,accent_hex,status`
      + `&limit=1`;

    const res = await fetch(url, {
      headers: {
        apikey: anonKey,
        Authorization: `Bearer ${anonKey}`,
        Accept: 'application/json',
      },
      /* Vercel honours this on the edge fetch cache. 60s matches our
         in-memory TTL so the two layers don't drift. */
      cf: { cacheTtl: 60, cacheEverything: true },
    });

    if (res.status === 404) {
      /* The tenants table itself doesn't exist yet. Same fail-open semantics
         as no env: route by slug only. */
      const result = { status: 'error', reason: 'table_missing' };
      tenantCache.set(slug, { data: result, expiresAt: Date.now() + NEGATIVE_CACHE_TTL_MS });
      return result;
    }
    if (!res.ok) {
      return { status: 'error', reason: `supabase_${res.status}` };
    }

    const rows = await res.json();
    if (!Array.isArray(rows) || rows.length === 0) {
      const result = { status: 'not_found' };
      tenantCache.set(slug, { data: result, expiresAt: Date.now() + NEGATIVE_CACHE_TTL_MS });
      return result;
    }

    const row = rows[0];
    tenantCache.set(slug, { data: row, expiresAt: Date.now() + TENANT_CACHE_TTL_MS });
    return row;
  } catch (e) {
    /* Network error, DNS failure, edge runtime panic — proceed gracefully. */
    return { status: 'error', reason: 'fetch_threw' };
  }
}


/* ─── Response helpers ───────────────────────────────────────────────── */

function rewriteToPage(target, request, opts = {}) {
  const response = rewrite(new URL(target, request.url));
  if (opts.headers) {
    for (const [k, v] of Object.entries(opts.headers)) {
      if (v !== null && v !== undefined) response.headers.set(k, String(v));
    }
  }
  /* @vercel/edge's rewrite() returns a Response whose status defaults to
     200. To preserve a non-200 semantic (404/410), construct a fresh
     Response carrying the same rewrite signal headers. */
  if (opts.status && opts.status !== 200) {
    const headers = new Headers(response.headers);
    return new Response(null, { status: opts.status, headers });
  }
  return response;
}

function injectTenantHeaders(response, tenant) {
  if (!tenant || tenant.status === 'error' || tenant.status === 'not_found') return response;
  response.headers.set('x-tenant-id',     tenant.id || '');
  response.headers.set('x-tenant-slug',   tenant.slug || '');
  response.headers.set('x-tenant-name',   tenant.display_name || '');
  response.headers.set('x-tenant-accent', tenant.accent_hex || '');
  response.headers.set('x-tenant-status', tenant.status || '');
  return response;
}


/* ─── Entry point ────────────────────────────────────────────────────── */

export default async function middleware(request) {
  const url = new URL(request.url);
  const pathname = url.pathname;

  /* 1 · Pass-through for static / internal. The matcher already filters
        most of this; this is belt-and-braces. */
  if (isStaticOrInternal(pathname)) return next();

  /* 2 · Brand book — exposed at /brandbook on any host. */
  if (pathname === '/brandbook' || pathname === '/brandbook/') {
    return rewrite(new URL('/Brand/brandbook.html', request.url));
  }

  const env  = getEnv();
  const apex = (env.PUBLIC_BASE_DOMAIN || 'theunionhub.com').toLowerCase();
  const host = request.headers.get('host');
  const { slug, isApex } = parseHost(host, apex);
  const page = normalisePath(pathname);

  /* 3 · Apex (marketing) — no tenant context. */
  if (isApex) {
    return rewrite(new URL(`/app/${page}.html`, request.url));
  }

  /* 4 · Tenant subdomain — resolve dataset, then rewrite. */
  const tenant = await resolveTenant(slug, env);

  /* 4a · Tenant lookup failed (Supabase down, table missing, env unset).
          Fail open: route by slug, let the page surface the issue. */
  if (tenant.status === 'error') {
    const target = resolveTenantTemplate(page);
    const response = rewrite(new URL(target, request.url));
    response.headers.set('x-tenant-slug', slug);
    response.headers.set('x-tenant-lookup', tenant.reason);
    return response;
  }

  /* 4b · Tenant doesn't exist — 404. */
  if (tenant.status === 'not_found') {
    return rewriteToPage('/404.html', request, {
      status: HTTP_NOT_FOUND,
      headers: { 'x-tenant-slug': slug, 'x-tenant-lookup': 'not_found' },
    });
  }

  /* 4c · Tenant exists but is archived — 410 Gone. */
  if (tenant.status === 'archived') {
    return rewriteToPage('/404.html', request, {
      status: HTTP_GONE,
      headers: {
        'x-tenant-id':     tenant.id,
        'x-tenant-slug':   tenant.slug,
        'x-tenant-status': 'archived',
      },
    });
  }

  /* 4d · Tenant exists but pending / suspended — same UX as archived
          but with the original status visible so the page can show the
          appropriate message. */
  if (tenant.status !== 'active') {
    return rewriteToPage('/404.html', request, {
      status: HTTP_NOT_FOUND,
      headers: {
        'x-tenant-id':     tenant.id,
        'x-tenant-slug':   tenant.slug,
        'x-tenant-status': tenant.status,
      },
    });
  }

  /* 4e · Happy path — active tenant. Rewrite to the template, inject
          headers so the page renders with zero additional fetches. */
  const target = resolveTenantTemplate(page);
  const response = rewrite(new URL(target, request.url));
  return injectTenantHeaders(response, tenant);
}

/**
 * Map a normalised page name to the static HTML file that serves it.
 *
 *   ''           → /tenants/_template/card.html          (legacy default)
 *   'index'      → /tenants/_template/card.html          (alias)
 *   'card'       → /tenants/_template/card.html
 *   'verify'     → /tenants/_template/verify.html
 *   'admin'      → /tenants/_template/admin/index.html   (directory default)
 *   'admin/sub'  → /tenants/_template/admin/sub.html
 *   '<other>'    → /tenants/_template/<other>.html       (Vercel 404s if missing)
 */
function resolveTenantTemplate(page) {
  if (page === 'admin') return '/tenants/_template/admin/index.html';
  if (page.startsWith('admin/')) {
    const sub = page.slice('admin/'.length);
    return `/tenants/_template/admin/${sub}.html`;
  }
  if (page === 'index' || page === '') return '/tenants/_template/card.html';
  return `/tenants/_template/${page}.html`;
}
