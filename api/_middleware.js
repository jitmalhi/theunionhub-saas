/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · api/_middleware.js
   Edge middleware: subdomain → tenant resolution + URL rewriting.

   This file is the single entry point that decides what file is served for
   every page request. It is imported by /middleware.js at the project root
   (which is the path Vercel actually scans for edge middleware). Keeping
   the logic here lets the architectural map in README.md ("api/_middleware.js")
   match the codebase, while /middleware.js is a one-line shim.

   Request flow:
     ┌─────────────────────────────────────────────────────────────────────┐
     │  Incoming request                                                   │
     │       ↓                                                             │
     │  Is this an internal/static path? (api, css, js, lib, Brand,        │
     │   _vercel, favicon, file with extension)                            │
     │       yes → next()  ┐                                               │
     │       no            ↓                                               │
     │  Parse host → derive slug (or null = apex/www)                      │
     │       ↓                                                             │
     │  slug ∈ RESERVED  → treat as apex                                   │
     │       ↓                                                             │
     │  slug === null    → rewrite to /app/<path>.html                     │
     │  slug !== null    → rewrite to /tenants/_template/<path>.html       │
     │                     + set x-tenant-slug header                      │
     └─────────────────────────────────────────────────────────────────────┘

   Tenant existence is NOT checked here. The page (or its data fetch) does
   the lookup against Supabase under RLS. Keeping the middleware DB-free
   keeps the cold path cheap — every request, including 404s, would
   otherwise pay a round-trip.

   For full tenant validation at the edge (status='active', 404/410 routing),
   wire in @vercel/edge-config or KV — see /docs/middleware.md (to come).
   ────────────────────────────────────────────────────────────────────────── */

import { next, rewrite } from '@vercel/edge';

export const config = {
  // Match everything except: explicit static asset paths, Vercel internals,
  // and obvious file requests (anything with a dot in the last segment).
  // The body of middleware() does the same check again so this file can
  // also run with looser matchers without misbehaving.
  matcher: '/((?!api/|_vercel/|css/|js/|lib/|Brand/|.*\\.[a-zA-Z0-9]+$).*)',
};

/* Slugs that must never resolve to a tenant. Mirror of the CHECK
   constraint on tenants.slug — keep these two in sync. */
const RESERVED_SLUGS = new Set([
  'www', 'app', 'api', 'admin', 'status', 'docs', 'blog',
  'mail', 'assets', 'cdn', 'static', 'demo-www',
]);

/* Marketing pages that live in /app. Anything not in this set falls
   through to /app/<path>.html (still works for files that exist; Vercel
   returns 404.html for files that don't). */
const APEX_PAGES = new Set([
  'index', 'about', 'audit-log', 'contact', 'data-processing',
  'privacy', 'security', 'status', 'terms',
]);

/* Tenant pages that live in /tenants/_template. */
const TENANT_PAGES = new Set(['card', 'verify']);

/**
 * Parse the request host into { slug, isApex }.
 *
 *   theunionhub.com           → { slug: null, isApex: true  }
 *   www.theunionhub.com       → { slug: null, isApex: true  } (www reserved)
 *   local183.theunionhub.com  → { slug: 'local183', isApex: false }
 *   demo.lvh.me:3000          → { slug: 'demo',     isApex: false }
 */
function parseHost(host, apex) {
  if (!host) return { slug: null, isApex: true };
  const bare = host.split(':')[0].toLowerCase();

  if (bare === apex) return { slug: null, isApex: true };
  if (bare.endsWith('.' + apex)) {
    const slug = bare.slice(0, -(apex.length + 1));
    if (RESERVED_SLUGS.has(slug)) return { slug: null, isApex: true };
    return { slug, isApex: false };
  }

  // Fallback for unknown hosts (preview deployments, lvh.me, etc.):
  // first label of host is the tentative slug.
  const parts = bare.split('.');
  if (parts.length >= 2) {
    const slug = parts[0];
    if (RESERVED_SLUGS.has(slug)) return { slug: null, isApex: true };
    return { slug, isApex: false };
  }
  return { slug: null, isApex: true };
}

/** Strip leading slash and trailing slash, return the bare path segment. */
function normalisePath(pathname) {
  const stripped = pathname.replace(/^\/+|\/+$/g, '');
  return stripped || 'index';
}

export default function middleware(request) {
  const url = new URL(request.url);
  const pathname = url.pathname;

  // Pass-through: static assets, API routes, Vercel internals.
  // The matcher already filters most of this; this is belt-and-braces.
  if (
    pathname.startsWith('/api/')   ||
    pathname.startsWith('/_vercel/') ||
    pathname.startsWith('/css/')   ||
    pathname.startsWith('/js/')    ||
    pathname.startsWith('/lib/')   ||
    pathname.startsWith('/Brand/') ||
    /\.[a-zA-Z0-9]+$/.test(pathname)
  ) {
    return next();
  }

  // Public brand book lives under /Brand — expose at /brandbook.
  if (pathname === '/brandbook' || pathname === '/brandbook/') {
    return rewrite(new URL('/Brand/brandbook.html', request.url));
  }

  const apex = (
    (typeof process !== 'undefined' && process.env && process.env.PUBLIC_BASE_DOMAIN) ||
    'theunionhub.com'
  ).toLowerCase();

  const host = request.headers.get('host');
  const { slug, isApex } = parseHost(host, apex);
  const page = normalisePath(pathname);

  // ─── Apex (marketing site) ───
  if (isApex) {
    const target = APEX_PAGES.has(page)
      ? `/app/${page}.html`
      : `/app/${page}.html`; // fall through; Vercel will 404 on missing pages
    return rewrite(new URL(target, request.url));
  }

  // ─── Tenant subdomain ───
  // Root of a tenant goes to the member card; other paths map by name.
  // Unknown tenant paths fall through to 404.html.
  const tenantPage = page === 'index'
    ? 'card'
    : (TENANT_PAGES.has(page) ? page : page);

  const target = `/tenants/_template/${tenantPage}.html`;
  const response = rewrite(new URL(target, request.url));
  response.headers.set('x-tenant-slug', slug);
  return response;
}
