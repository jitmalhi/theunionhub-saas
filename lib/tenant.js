/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/tenant.js
   Browser-side tenant resolver + theming.

   Single source of truth for "what tenant is this page?" once the request
   has reached the browser. The edge middleware (api/_middleware.js) has
   already proven the tenant exists and is active — this module's job is
   to surface its display_name / accent_hex / local_number into the DOM
   without forcing every page to re-implement the lookup.

   Why we re-fetch the tenant client-side even though the middleware
   already resolved it:

     The edge sets x-tenant-{id,name,accent,…} response headers, but
     HTML pages cannot read their own response headers from JS in any
     portable way (no DOM API exposes them). The middleware *could* be
     extended to inject a <script> tag into the HTML body, but that
     requires response-body rewriting which is more complex and adds
     edge latency to every render. Instead:

       · Middleware proves existence + injects headers (debuggable via
         curl, observable in DevTools Network panel).
       · Client re-fetches the row directly from Supabase under the
         permissive anon SELECT policy on public.tenants. Result is
         cached in sessionStorage for the rest of the visit.

     The double-fetch is cheap (Supabase REST + edge cache, ~30ms) and
     keeps the two layers independent — the page works even when the
     middleware fails open.

   No npm deps. No build step. Uses lib/supabase.js, sessionStorage,
   and standard DOM only. Works in any modern browser that supports
   ES modules.
   ────────────────────────────────────────────────────────────────────────── */

import { createClient } from '/lib/supabase.js';

const CACHE_KEY  = 'uh:tenant:v1';
const POSITIVE_TTL_MS = 60_000;   // tenant data found
const NEGATIVE_TTL_MS = 10_000;   // tenant data confirmed absent (apex, unknown slug)

/* Mirror of RESERVED_SLUGS in api/_middleware.js and the CHECK in
   supabase/migrations/0001_init_tenants.sql. The three lists must move
   in lockstep. */
const RESERVED_SLUGS = new Set([
  'www', 'app', 'api', 'admin', 'status', 'docs', 'blog',
  'mail', 'assets', 'cdn', 'static', 'demo-www',
]);


/* ════════════════════════════════════════════════════════════════════════
   1 · SLUG PARSING
   ════════════════════════════════════════════════════════════════════════ */

function getApexDomain() {
  return (
    (typeof window !== 'undefined' && window.__UH_CONFIG__ && window.__UH_CONFIG__.PUBLIC_BASE_DOMAIN) ||
    'theunionhub.com'
  ).toLowerCase();
}

/**
 * Derive the tenant slug from a hostname.
 *
 *   theunionhub.com           → null  (apex; marketing site)
 *   www.theunionhub.com       → null  (reserved)
 *   local183.theunionhub.com  → 'local183'
 *   demo.theunionhub.com      → 'demo'
 *   demo.lvh.me               → 'demo'  (dev fallback: first label)
 *   localhost                 → null
 */
export function getTenantSlugFromHost(host) {
  host = (host || (typeof window !== 'undefined' ? window.location.hostname : '') || '').toLowerCase();
  if (!host) return null;
  host = host.split(':')[0];

  const apex = getApexDomain();

  if (host === apex) return null;
  if (host.endsWith('.' + apex)) {
    const slug = host.slice(0, -(apex.length + 1));
    return RESERVED_SLUGS.has(slug) ? null : slug;
  }

  /* Dev / preview fallback: any multi-label host (lvh.me, *.vercel.app)
     uses its first label as the tentative slug. */
  const parts = host.split('.');
  if (parts.length >= 2) {
    const slug = parts[0];
    return RESERVED_SLUGS.has(slug) ? null : slug;
  }
  return null;
}


/* ════════════════════════════════════════════════════════════════════════
   2 · SESSION-STORAGE CACHE
   ════════════════════════════════════════════════════════════════════════ */

/* Three return shapes:
     undefined  → cache miss / expired (caller should re-fetch)
     null       → cache hit, but tenant doesn't exist (negative cache)
     object     → cache hit, full tenant row */
function readCache(slug) {
  try {
    const raw = sessionStorage.getItem(CACHE_KEY);
    if (!raw) return undefined;
    const c = JSON.parse(raw);
    if (c.slug !== slug) return undefined;
    if (Date.now() - c.fetchedAt > c.ttl) return undefined;
    return c.data;
  } catch {
    return undefined;
  }
}

function writeCache(slug, data) {
  try {
    sessionStorage.setItem(CACHE_KEY, JSON.stringify({
      slug,
      data,
      fetchedAt: Date.now(),
      ttl: data === null ? NEGATIVE_TTL_MS : POSITIVE_TTL_MS,
    }));
  } catch {
    /* sessionStorage can throw (private mode, quota). Swallow — fetching
       again is cheaper than failing the page. */
  }
}

export function clearCache() {
  try { sessionStorage.removeItem(CACHE_KEY); } catch { /* ignore */ }
}


/* ════════════════════════════════════════════════════════════════════════
   3 · TENANT FETCH (with in-flight dedupe)
   ════════════════════════════════════════════════════════════════════════ */

let inflight = null;

/**
 * Resolve the current tenant. Returns:
 *   { id, slug, display_name, local_number, union_type, accent_hex, status }
 * on success, or null when there is no tenant (apex, reserved slug,
 * slug not in DB, or any error — fail gracefully so the page still renders).
 *
 *   await getTenant()              // standard, cache-aware
 *   await getTenant({ force: true }) // bypass cache, refetch
 */
export async function getTenant({ force = false } = {}) {
  const slug = getTenantSlugFromHost();
  if (!slug) return null;

  if (!force) {
    const cached = readCache(slug);
    if (cached !== undefined) return cached;
  }

  if (inflight) return inflight;

  inflight = (async () => {
    try {
      const client = createClient();
      const { data } = await client
        .from('tenants')
        .select('id,slug,display_name,local_number,union_type,accent_hex,status,logo_url')
        .eq('slug', slug)
        .single();

      /* Only treat 'active' as a usable tenant. Suspended/archived/pending
         are real rows but the middleware has already returned 404/410 for
         them — if we got here under one of those, the dev DB is out of
         sync with prod routing. Treat as null. */
      const usable = data && data.status === 'active' ? data : null;
      writeCache(slug, usable);
      return usable;
    } catch (e) {
      /* Most likely cause: tenants table doesn't exist yet (early
         scaffold) or RLS blocked the read. Either way the page should
         render without tenant data, not crash. */
      console.warn('[uh/tenant] resolve failed:', e && e.message ? e.message : e);
      writeCache(slug, null);
      return null;
    } finally {
      inflight = null;
    }
  })();

  return inflight;
}


/* ════════════════════════════════════════════════════════════════════════
   4 · THEMING
   ════════════════════════════════════════════════════════════════════════ */

/**
 * Paint the tenant into the DOM. Two layers:
 *
 *   1. CSS — sets --accent-tenant on :root and data-tenant-{accent,slug,status}
 *      on <body>. Combined with tenants/_template/tenant.css (which scopes
 *      tenant-accent overrides under [data-tenant-accent="true"]), this is
 *      what lights up the per-tenant colour.
 *
 *   2. Content — replaces .textContent of any element carrying
 *      [data-tenant-name], [data-tenant-local], [data-tenant-slug-text].
 *      Pages that pre-render with hardcoded strings can opt in by adding
 *      these attributes; pages that pre-render with patched data (like
 *      card.html, which patches the `member` object before render) can
 *      ignore this layer.
 *
 * Both layers are idempotent. Safe to call multiple times (e.g., after
 * each re-render of a dynamic component).
 */
export function applyTenantTheme(tenant, opts = {}) {
  if (!tenant) return;
  const root  = opts.root  || document.documentElement;
  const scope = opts.scope || document;

  /* ── CSS layer ── */
  if (tenant.accent_hex) {
    root.style.setProperty('--accent-tenant', tenant.accent_hex);
  }
  if (document.body) {
    document.body.setAttribute('data-tenant-accent', 'true');
    document.body.setAttribute('data-tenant-slug',   tenant.slug   || '');
    document.body.setAttribute('data-tenant-status', tenant.status || '');
  }

  /* ── Content layer ── */
  const replace = (sel, value) => {
    if (value == null) return;
    scope.querySelectorAll(sel).forEach((el) => { el.textContent = value; });
  };
  replace('[data-tenant-name]',       tenant.display_name);
  replace('[data-tenant-local]',      tenant.local_number);
  replace('[data-tenant-slug-text]',  tenant.slug);

  /* Logo: only replaces existing slot content when tenant.logo_url is
     set. Pages that wrap a fallback SVG in [data-tenant-logo] keep
     that SVG when no tenant logo exists. DOM-built (replaceChildren +
     appendChild) rather than innerHTML so display_name with a quote
     can't escape the alt attribute. */
  if (tenant.logo_url) {
    scope.querySelectorAll('[data-tenant-logo]').forEach((el) => {
      const img = document.createElement('img');
      img.src = tenant.logo_url;
      img.alt = tenant.display_name || '';
      el.replaceChildren(img);
    });
  }
}


/* ════════════════════════════════════════════════════════════════════════
   5 · ONE-LINER INIT
   ════════════════════════════════════════════════════════════════════════ */

/**
 * Resolve + paint in one call. Returns the tenant (or null).
 *
 *   import { init } from '/lib/tenant.js';
 *   const tenant = await init();
 *
 * Defers content-layer paint until DOMContentLoaded if <body> isn't ready
 * yet, so the call site doesn't have to care about timing.
 */
export async function init(opts = {}) {
  const tenant = await getTenant();
  if (!tenant) return null;

  if (document.body) {
    applyTenantTheme(tenant, opts);
  } else {
    document.addEventListener(
      'DOMContentLoaded',
      () => applyTenantTheme(tenant, opts),
      { once: true }
    );
  }
  return tenant;
}

export default {
  getTenant,
  applyTenantTheme,
  getTenantSlugFromHost,
  clearCache,
  init,
};
