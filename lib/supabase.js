/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/supabase.js
   Tenant-aware Supabase client factory.

   Replaces the hardcoded URL + anon key in the prototype `js/live.js`.
   Works in three runtimes:
     1. Browser           — reads window.__UH_CONFIG__ injected by middleware.
     2. Vercel Edge       — reads env from globalThis (SUPABASE_URL, etc.).
     3. Node (serverless) — reads process.env.

   This is a fetch-thin wrapper, not @supabase/supabase-js. The brand rule
   "no runtime npm deps" still holds: zero dependencies, ES module, works
   anywhere fetch + URL exist.

   Tenancy contract:
     - Every query must run inside a tenant context.
     - The middleware sets x-tenant-id on every page render; the page
       passes it back via createClient({ tenantId }).
     - RLS on Supabase enforces that auth.jwt() ->> 'tenant_id' equals the
       row's tenant_id. The client merely *passes* the tenant id; it does
       not enforce it. Never trust the client.
   ────────────────────────────────────────────────────────────────────────── */

const PROD_FALLBACK_URL = 'https://frdvhmzbsmczknqtexvx.supabase.co';

/**
 * Resolve runtime config. Order of precedence:
 *   1. explicit arg          → createClient({ url, anonKey })
 *   2. window.__UH_CONFIG__   → browser, injected by middleware
 *   3. process.env / globalThis → edge & serverless
 *   4. PROD_FALLBACK_URL only  → last-ditch for the cutover window
 *
 * Throws if the anon key cannot be resolved — there is no safe default.
 */
export function resolveConfig(overrides = {}) {
  const env =
    (typeof process !== 'undefined' && process.env) ||
    (typeof globalThis !== 'undefined' && globalThis.process && globalThis.process.env) ||
    {};

  const browserCfg =
    typeof window !== 'undefined' && window.__UH_CONFIG__
      ? window.__UH_CONFIG__
      : {};

  const url =
    overrides.url ||
    browserCfg.SUPABASE_URL ||
    env.SUPABASE_URL ||
    env.NEXT_PUBLIC_SUPABASE_URL ||
    PROD_FALLBACK_URL;

  const anonKey =
    overrides.anonKey ||
    browserCfg.SUPABASE_ANON_KEY ||
    env.SUPABASE_ANON_KEY ||
    env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!anonKey) {
    throw new Error(
      '[uh/supabase] SUPABASE_ANON_KEY missing. ' +
      'Set it in .env.local, inject via middleware (window.__UH_CONFIG__), ' +
      'or pass createClient({ anonKey }).'
    );
  }

  return {
    url: url.replace(/\/+$/, ''),
    anonKey,
    tenantId: overrides.tenantId || browserCfg.TENANT_ID || null,
    fetch: overrides.fetch || globalThis.fetch.bind(globalThis),
  };
}

/**
 * Build standard Supabase REST headers.
 * The tenant id rides as a custom header that RLS policies inspect via
 * `current_setting('request.headers', true)::json ->> 'x-tenant-id'`.
 */
function buildHeaders(cfg, extras = {}) {
  const h = {
    apikey: cfg.anonKey,
    Authorization: 'Bearer ' + cfg.anonKey,
    'Content-Type': 'application/json',
    Prefer: 'return=representation',
  };
  if (cfg.tenantId) h['x-tenant-id'] = cfg.tenantId;
  return Object.assign(h, extras);
}

/**
 * Tiny query builder. Supports:
 *   client.from('members').select('*').eq('id', uuid).single()
 *   client.from('members').select('id,name').limit(20)
 *
 * Not a full pg-rest port — just the slice the prototype uses. Extend as
 * pages need more; do NOT pull in @supabase/supabase-js without a reason
 * that survives review.
 */
function tableQuery(cfg, table) {
  const params = new URLSearchParams();
  let _select = '*';
  let _single = false;

  const api = {
    select(cols = '*') { _select = cols; return api; },
    eq(col, val)       { params.append(col, 'eq.' + val); return api; },
    in(col, vals)      { params.append(col, 'in.(' + vals.join(',') + ')'); return api; },
    limit(n)           { params.set('limit', String(n)); return api; },
    order(col, opts)   {
      const dir = opts && opts.ascending === false ? 'desc' : 'asc';
      params.set('order', col + '.' + dir);
      return api;
    },
    single()           { _single = true; return api; },

    async exec() {
      params.set('select', _select);
      const url = `${cfg.url}/rest/v1/${table}?${params.toString()}`;
      const headers = buildHeaders(cfg, _single ? { Accept: 'application/vnd.pgrst.object+json' } : {});
      const res = await cfg.fetch(url, { method: 'GET', headers });
      if (!res.ok) {
        const body = await res.text().catch(() => '');
        const err = new Error(`[uh/supabase] ${res.status} ${res.statusText} on ${table}: ${body}`);
        err.status = res.status;
        throw err;
      }
      const data = await res.json();
      return { data, error: null };
    },

    // Convenience: await the builder directly (await client.from('x').select())
    then(onFulfilled, onRejected) { return api.exec().then(onFulfilled, onRejected); },
  };
  return api;
}

/**
 * Public client factory. Pass overrides to bind a specific tenant context.
 */
export function createClient(overrides = {}) {
  const cfg = resolveConfig(overrides);

  return {
    config: cfg,
    from(table) { return tableQuery(cfg, table); },

    /** Direct REST escape hatch — for RPC, storage, or anything not above. */
    async raw(path, init = {}) {
      const url = path.startsWith('http') ? path : cfg.url + path;
      const headers = buildHeaders(cfg, init.headers || {});
      const res = await cfg.fetch(url, Object.assign({}, init, { headers }));
      return res;
    },

    /** Re-bind to a different tenant without re-resolving env. */
    withTenant(tenantId) {
      return createClient(Object.assign({}, overrides, cfg, { tenantId }));
    },
  };
}

export default createClient;
