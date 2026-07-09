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

     1. Skip — static assets, /api/, /css/, /lib/, /Brand/, /_vercel/
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
import { RESERVED_SLUGS } from '../lib/reserved-slugs.js';
import { serverConfigForHost } from '../lib/domains.js';

export const config = {
  /* Exclude internal rewrite targets (app/, tenants/) so a cleanUrls
     308 from /app/about.html → /app/about doesn't re-enter middleware
     and loop into /app/app/app/... The two explicit SEO paths are added so the
     middleware can serve host-specific robots/sitemap for Tier-1 website hosts
     (they'd otherwise be excluded by the extension rule). */
  matcher: [
    '/((?!api/|_vercel/|css/|lib/|Brand/|app/|tenants/|.*\\.[a-zA-Z0-9]+$).*)',
    '/robots.txt',
    '/sitemap.xml',
  ],
};

/* ─── Constants ───────────────────────────────────────────────────────── */

/* RESERVED_SLUGS is imported from ../lib/reserved-slugs.js — the single source
   shared with lib/tenant.js. The CHECK constraint on tenants.slug (migration
   0001) mirrors it (SQL can't import JS); keep them in sync, and
   tenants/README.md too. */

/* Pages that live under /tenants/_template. Anything else falls through
   to a 404 via Vercel's normal handling. */
const TENANT_PAGES = new Set(['card', 'verify', 'index', 'access']);

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
    /* Internal rewrite targets — must skip middleware on the second pass
       when cleanUrls 308s our rewritten URL back into the request loop.
       Without this, /app/about → middleware → /app/app/about → ... ∞.
       Include the no-slash form: cleanUrls strips /app/index.html → /app
       (both .html AND /index get stripped), and /app must not re-enter. */
    pathname === '/app'   || pathname.startsWith('/app/')   ||
    pathname === '/tenants' || pathname.startsWith('/tenants/') ||
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
async function resolveTenant(slug, cfg) {
  if (!slug) return { status: 'not_found' };

  /* Cache check */
  const cached = tenantCache.get(slug);
  if (cached && cached.expiresAt > Date.now()) return cached.data;

  const supabaseUrl = cfg.supabaseUrl;
  const anonKey     = cfg.anonKey;

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
      /* No edge-fetch cache hint: the `cf` option is Cloudflare-only and is
         ignored on Vercel. Tenant lookups are served from the in-memory
         tenantCache (TTL above) instead. */
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
  const response = rewrite(target);
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

  /* 0 · Per-site SEO files for Tier-1 website hosts. robots.txt / sitemap.xml
        are host-specific for {slug}.theunionhub.ca — route them to the site
        renderer (which generates them). The .com app / apex fall through to the
        static files. Handled before the static passthrough because these are
        extension paths that isStaticOrInternal() would otherwise wave through. */
  if (pathname === '/robots.txt' || pathname === '/sitemap.xml') {
    const h = request.headers.get('host') || '';
    const a = serverConfigForHost(h, getEnv()).apex.toLowerCase();
    if (a === 'theunionhub.ca' && !parseHost(h, a).isApex) {
      const r = rewrite(new URL('/api/site', request.url));
      r.headers.set('x-site-host', h);
      r.headers.set('x-site-path', pathname);
      return r;
    }
    return next();
  }

  /* 1 · Pass-through for static / internal. The matcher already filters
        most of this; this is belt-and-braces. */
  if (isStaticOrInternal(pathname)) return next();

  /* 2 · Brand book — exposed at /brandbook on any host. */
  if (pathname === '/brandbook' || pathname === '/brandbook/') {
    return rewrite('/Brand/brandbook.html');
  }

  const env  = getEnv();
  const host = request.headers.get('host');

  /* Region-aware config for THIS host (theunionhub.com vs theunionhub.ca): the
     apex + the Supabase project the middleware queries. env.PUBLIC_BASE_DOMAIN
     still overrides the apex for local dev (e.g. lvh.me); leave it UNSET in
     production so the per-host registry drives both domains. */
  const hostCfg = serverConfigForHost(host, env);
  const apex = (env.PUBLIC_BASE_DOMAIN || hostCfg.apex).toLowerCase();

  const { slug, isApex } = parseHost(host, apex);
  const page = normalisePath(pathname);

  /* 3a · Tier-1 public websites — {slug}.theunionhub.ca (and, in phase 3, custom
         domains). Route to the server-side site renderer, which resolves the
         tenant by full hostname (tenant_hostnames) and renders the published
         site. The .com app path (card/verify/access/admin) below is untouched;
         the apex .ca marketing site (isApex) also falls through unchanged. */
  if (!isApex && apex === 'theunionhub.ca') {
    const siteResp = rewrite(new URL('/api/site', request.url));
    siteResp.headers.set('x-site-host', host || '');
    return siteResp;
  }

  /* 3b · Apex (marketing) — no tenant context. */
  if (isApex) {
    return rewrite(`/app/${page}.html`);
  }

  /* 4 · Tenant subdomain — resolve dataset from this host's Supabase project,
          then rewrite. */
  const tenant = await resolveTenant(slug, hostCfg);

  /* 4a · Tenant lookup failed (Supabase down, table missing, env unset).
          Fail open: route by slug, let the page surface the issue. */
  if (tenant.status === 'error') {
    const target = resolveTenantTemplate(page);
    const response = rewrite(target);
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
  const response = rewrite(target);
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
  /* Public representative profile. Both /access and the path-style
     /access/<id> serve the single access.html template; the page reads the
     id from location.pathname (the browser keeps the pretty URL — this
     rewrite is internal) or from ?id=. Without this branch, /access/<id>
     would map to the non-existent /tenants/_template/access/<id>.html.
     The self-portal (/access/portal/…) is deliberately excluded so it falls
     through to its own nested templates via the generic mapping below. */
  if (page === 'access' || (page.startsWith('access/') && !page.startsWith('access/portal'))) {
    return '/tenants/_template/access.html';
  }

  /* Member View — /meet and the path-style /meet/<steward-id> both serve the
     single access/meet.html template; the page reads the id from the path.
     This is where a member lands after scanning a steward's QR. */
  if (page === 'meet' || page.startsWith('meet/')) {
    return '/tenants/_template/access/meet.html';
  }

  /* Home / index → the digital card. */
  if (page === 'index' || page === '') return '/tenants/_template/card.html';

  /* Everything else maps 1:1 to a template file (Vercel 404s if missing):
     verify → verify.html, access/portal/login → access/portal/login.html, … */
  return `/tenants/_template/${page}.html`;
}

