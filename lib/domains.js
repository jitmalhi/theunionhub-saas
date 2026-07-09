/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/domains.js
   Host → configuration registry. THE single source of truth for "which apex
   am I, and which Supabase project do I talk to?" — the foundation of running
   theunionhub.com and theunionhub.ca from one codebase.

   Why this exists:
     The platform serves multiple country domains from one deployment, but
     each country will keep its data in its OWN Supabase project (data-residency
     goal — a Canadian project for .ca). Note the CURRENT state: the .com
     project already runs in ca-central-1 and the .ca project is not yet
     provisioned, so today all data is in Canada. So config can't be a
     single compile-time constant or a single env var; it must be chosen by the
     REQUEST HOST. This module is that lookup.

   Two resolvers:
     · configForHost(host)            → the baked, public registry entry.
       Used in the BROWSER (no env), where the anon key is RLS-safe and
       intentionally public, so baking it in keeps the no-build model.
     · serverConfigForHost(host, env) → registry + per-region env overrides.
       Used by the edge middleware and /api routes, which may also need the
       secret service-role key (NEVER baked in — env only).

   Region safety (the important bit):
     serverConfigForHost honours the LEGACY unsuffixed env vars (SUPABASE_URL,
     SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY) ONLY for the DEFAULT region.
     A non-default region (e.g. CA) is resolved from its own suffixed env
     (SUPABASE_URL_CA, …) or the baked registry — so a single global
     SUPABASE_URL set for .com can never silently leak into .ca. This is what
     lets the current single-region setup (and .env.local) keep working
     unchanged while the second region is added safely.

   Pure ESM, no dependencies — imports cleanly in browser / edge / serverless.
   ────────────────────────────────────────────────────────────────────────── */

/* The registry. Keys are registrable (apex) domains. Anon keys are RLS-safe
   publishable keys — public by design (RLS is the boundary, not secrecy).
   The .com entry holds the exact values that were previously the
   PROD_FALLBACK_* constants in lib/supabase.js, so .com behaves identically. */
export const DOMAINS = {
  'theunionhub.com': {
    apex:        'theunionhub.com',
    // `region` is an ENV-NAMESPACE label (it drives the SUPABASE_*_US env-var
    // suffixing below), NOT the database's physical region. The .com Supabase
    // project currently runs in ca-central-1. Do not repurpose this value to
    // mean the physical region — it namespaces the .com env vars.
    region:      'us',
    supabaseUrl: 'https://frdvhmzbsmczknqtexvx.supabase.co',
    anonKey:     'sb_publishable_mQ5Y9tjHHQmc9gCZPB_tHA_OwHXTc9P',
  },
  'theunionhub.ca': {
    apex:        'theunionhub.ca',
    region:      'ca',
    /* TODO: fill when the Canadian Supabase project exists. Until then, a .ca
       host fails loudly (resolveConfig throws on the empty anonKey) rather than
       silently talking to the US project. */
    supabaseUrl: '',
    anonKey:     '',
  },
};

/* The fallback apex for any host not in the registry — localhost, *.lvh.me,
   *.vercel.app preview deploys. Keeping this as .com preserves the previous
   behaviour exactly (those hosts resolved to the .com fallbacks before). */
export const DEFAULT_DOMAIN = 'theunionhub.com';

/* Map any host (apex or subdomain, with/without port) to its registrable
   domain key, or null if it isn't one of ours (dev/preview hosts). */
export function registrableDomain(host) {
  const bare = String(host || '').split(':')[0].toLowerCase().replace(/\.$/, '');
  if (!bare) return null;
  if (DOMAINS[bare]) return bare;
  for (const key of Object.keys(DOMAINS)) {
    if (bare === key || bare.endsWith('.' + key)) return key;
  }
  return null;
}

/**
 * The baked registry entry for a host. Browser-safe (no secrets, no env).
 * Unknown hosts fall back to DEFAULT_DOMAIN (.com) — same as the old
 * PROD_FALLBACK_* behaviour.
 *
 *   configForHost('local183.theunionhub.ca') → the .ca entry
 *   configForHost('demo.lvh.me')             → the .com entry (default)
 */
export function configForHost(host) {
  return DOMAINS[registrableDomain(host) || DEFAULT_DOMAIN];
}

/** Just the apex for a host (e.g. 'theunionhub.ca'). */
export function apexForHost(host) {
  return configForHost(host).apex;
}

/**
 * Server-side resolver: the baked entry, layered with env overrides.
 *
 * Precedence per field:
 *   1. per-region suffixed env   (SUPABASE_URL_US / _CA, …)
 *   2. legacy unsuffixed env     — DEFAULT region ONLY (back-compat / dev)
 *   3. baked registry value
 *
 * Returns { apex, region, supabaseUrl, anonKey, serviceRoleKey }. The
 * serviceRoleKey is env-only (never baked) and null when unset.
 */
export function serverConfigForHost(host, env = {}) {
  const key  = registrableDomain(host) || DEFAULT_DOMAIN;
  const base = DOMAINS[key];
  const R    = base.region.toUpperCase();
  const isDefault = key === DEFAULT_DOMAIN;

  const pick = (suffixed, legacy, baked) =>
    env[suffixed] || (isDefault ? legacy : '') || baked || '';

  return {
    apex:           base.apex,
    region:         base.region,
    supabaseUrl:    pick(`SUPABASE_URL_${R}`,              env.SUPABASE_URL,              base.supabaseUrl),
    anonKey:        pick(`SUPABASE_ANON_KEY_${R}`,         env.SUPABASE_ANON_KEY,         base.anonKey),
    serviceRoleKey: pick(`SUPABASE_SERVICE_ROLE_KEY_${R}`, env.SUPABASE_SERVICE_ROLE_KEY, '') || null,
  };
}

export default { DOMAINS, DEFAULT_DOMAIN, registrableDomain, configForHost, apexForHost, serverConfigForHost };
