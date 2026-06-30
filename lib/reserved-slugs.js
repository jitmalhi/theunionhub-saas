/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/reserved-slugs.js
   Single source of truth for subdomain labels that must NEVER resolve to a
   tenant (they're platform routes, not unions).

   Previously this Set was copy-pasted into api/_middleware.js, lib/tenant.js,
   and api/access-event.js — three places to forget when adding a reserved
   word. They now all import from here.

   STILL COUPLED, by necessity: the CHECK constraint on tenants.slug
   (migration 0001) enforces the same list at the database. SQL can't import
   this module — so when you change this set, update that constraint too (and
   tenants/README.md). This file is the canonical list; the DB mirrors it.

   Pure ESM, no dependencies — safe to import from the browser (absolute
   '/lib/reserved-slugs.js'), the edge middleware, and serverless functions
   (relative '../lib/reserved-slugs.js').
   ────────────────────────────────────────────────────────────────────────── */

export const RESERVED_SLUGS = new Set([
  'www', 'app', 'api', 'admin', 'status', 'docs', 'blog',
  'mail', 'assets', 'cdn', 'static', 'demo-www',
]);

/** Convenience predicate so callers don't each reach into the Set. */
export function isReservedSlug(slug) {
  return RESERVED_SLUGS.has(String(slug || '').toLowerCase());
}

export default RESERVED_SLUGS;
