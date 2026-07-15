/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/domains.js
   Host → configuration registry. THE single source of truth for "which apex
   am I, and which Supabase project do I talk to?" — the foundation of running
   theunionhub.ca (primary) with theunionhub.com kept as a defensive alias
   from one codebase.

   Why this exists:
     The platform serves multiple country domains from one deployment, but
     each country will keep its data in its OWN Supabase project (data-residency
     goal — a Canadian project for .ca). Current state: theunionhub.ca is the
     canonical domain and its Supabase project already runs in ca-central-1
     (Montréal); theunionhub.com is owned defensively and 301-redirected to
     .ca upstream, but is kept in the registry so a stray pre-redirect .com
     request still resolves to the same Canadian project. So config can't be a
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
   theunionhub.ca is the primary/default entry and holds the working Canadian
   Supabase project (ca-central-1, Montréal). theunionhub.com is kept as a
   defensive alias pointing at the SAME project, so a stray .com request that
   arrives before the upstream 301 redirect still resolves identically. */
export const DOMAINS = {
  'theunionhub.ca': {
    apex:        'theunionhub.ca',
    // `region` is an ENV-NAMESPACE label (it drives the SUPABASE_*_CA env-var
    // suffixing below). Here it also matches the physical region: this project
    // runs in ca-central-1 (Montréal).
    region:      'ca',
    supabaseUrl: 'https://frdvhmzbsmczknqtexvx.supabase.co',
    anonKey:     'sb_publishable_mQ5Y9tjHHQmc9gCZPB_tHA_OwHXTc9P',
  },
  'theunionhub.com': {
    // Defensive alias — .com is 301-redirected to .ca upstream (GoDaddy), but
    // kept here (pointing at the SAME project) so any pre-redirect .com traffic
    // still resolves identically. `region: 'us'` only namespaces its env vars.
    apex:        'theunionhub.com',
    region:      'us',
    supabaseUrl: 'https://frdvhmzbsmczknqtexvx.supabase.co',
    anonKey:     'sb_publishable_mQ5Y9tjHHQmc9gCZPB_tHA_OwHXTc9P',
  },
};

/* The fallback apex for any host not in the registry — localhost, *.lvh.me,
   *.vercel.app preview deploys. Now theunionhub.ca (primary), so dev/preview
   hosts resolve to the Canadian project. */
export const DEFAULT_DOMAIN = 'theunionhub.ca';

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
 * Unknown hosts fall back to DEFAULT_DOMAIN (.ca) — the Canadian project.
 *
 *   configForHost('local183.theunionhub.ca') → the .ca entry
 *   configForHost('demo.lvh.me')             → the .ca entry (default)
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
