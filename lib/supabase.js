/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/supabase.js
   Tenant-aware Supabase client with magic-link auth.

   Three layers:
     1. Config resolution        env / window / explicit overrides
     2. Auth (magic-link only)   signInWithOtp, verifyOtp, getSession,
                                 refreshSession, onAuthStateChange, signOut
     3. Data access              from(table).select().eq().single() …

   Runtimes:
     · Browser     → reads window.__UH_CONFIG__ injected by middleware;
                     persists session in localStorage.
     · Edge        → reads env from globalThis; session methods no-op
                     (no localStorage on the edge — auth is page-side).
     · Serverless  → reads from process.env; session methods no-op.

   Hard rules (from the brand book + product spec):
     · No passwords. Magic link only. signInWithPassword is intentionally
       absent and will throw if referenced.
     · Tenant context rides on every authenticated request via x-tenant-id;
       RLS policies inspect it. Never enforce tenancy in the client.
     · No npm runtime deps. This file is fetch + URL + localStorage. If you
       feel the urge to add @supabase/supabase-js, write a one-pager
       justifying it first.
   ────────────────────────────────────────────────────────────────────────── */

const PROD_FALLBACK_URL = 'https://frdvhmzbsmczknqtexvx.supabase.co';

/* Storage key is namespaced per project so multiple projects on the same
   origin (impossible in prod, common in dev) don't trample each other. */
function storageKey(url) {
  const m = url.match(/^https?:\/\/([a-z0-9-]+)\./i);
  return `sb-uh-auth-${m ? m[1] : 'default'}`;
}

/* Refresh access tokens this many seconds before they expire. */
const REFRESH_LEAD_SECONDS = 60;

/* ════════════════════════════════════════════════════════════════════════
   1 · CONFIG RESOLUTION
   ════════════════════════════════════════════════════════════════════════ */

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
    tenantId:
      overrides.tenantId ||
      browserCfg.TENANT_ID ||
      browserCfg.tenantId ||
      null,
    tenantSlug:
      overrides.tenantSlug ||
      browserCfg.TENANT_SLUG ||
      browserCfg.tenantSlug ||
      null,
    fetch: overrides.fetch || globalThis.fetch.bind(globalThis),
    storage: overrides.storage || resolveStorage(),
    autoRefresh: overrides.autoRefresh !== false,   // default: on in browser
  };
}

/* Pick a storage backend. localStorage in the browser, an in-memory Map
   stub everywhere else so the auth code never has to branch. */
function resolveStorage() {
  if (typeof window !== 'undefined' && window.localStorage) {
    return {
      get: (k) => window.localStorage.getItem(k),
      set: (k, v) => window.localStorage.setItem(k, v),
      del: (k) => window.localStorage.removeItem(k),
    };
  }
  const m = new Map();
  return {
    get: (k) => (m.has(k) ? m.get(k) : null),
    set: (k, v) => m.set(k, v),
    del: (k) => m.delete(k),
  };
}


/* ════════════════════════════════════════════════════════════════════════
   2 · AUTH (magic-link only)
   ════════════════════════════════════════════════════════════════════════ */

function makeAuth(cfg) {
  const key = storageKey(cfg.url);
  const listeners = new Set();
  let refreshTimer = null;
  let inflightRefresh = null;       // de-dupe concurrent refresh calls

  function loadSession() {
    try {
      const raw = cfg.storage.get(key);
      if (!raw) return null;
      const s = JSON.parse(raw);
      if (!s || !s.access_token || !s.refresh_token) return null;
      return s;
    } catch {
      cfg.storage.del(key);
      return null;
    }
  }

  function saveSession(session) {
    if (!session) {
      cfg.storage.del(key);
      scheduleRefresh(null);
      emit('SIGNED_OUT', null);
      return;
    }
    /* Normalise: ensure expires_at (epoch seconds) is set; Supabase returns
       both expires_in (seconds from now) and expires_at — prefer expires_at,
       compute from expires_in if missing. */
    const expiresAt =
      session.expires_at ||
      (session.expires_in
        ? Math.floor(Date.now() / 1000) + Number(session.expires_in)
        : null);

    const normalised = Object.assign({}, session, { expires_at: expiresAt });
    cfg.storage.set(key, JSON.stringify(normalised));
    scheduleRefresh(normalised);
    emit('SIGNED_IN', normalised);
  }

  function emit(event, session) {
    for (const l of listeners) {
      try { l(event, session); } catch (e) { /* never let a listener throw */ }
    }
  }

  function scheduleRefresh(session) {
    if (refreshTimer) { clearTimeout(refreshTimer); refreshTimer = null; }
    if (!cfg.autoRefresh || !session || !session.expires_at) return;

    const nowSec = Math.floor(Date.now() / 1000);
    const leadMs = Math.max(0, (session.expires_at - REFRESH_LEAD_SECONDS - nowSec) * 1000);
    refreshTimer = setTimeout(() => { auth.refreshSession().catch(() => {}); }, leadMs);
  }

  const auth = {
    /**
     * Send a magic link to the given email. The link lands on `emailRedirectTo`
     * (default: current origin /auth/callback) carrying a `token_hash` and
     * `type=magiclink` — the callback page must call verifyOtp() with those.
     */
    async signInWithOtp({ email, options = {} } = {}) {
      if (!email) throw new Error('[uh/auth] signInWithOtp requires { email }');

      const emailRedirectTo =
        options.emailRedirectTo ||
        (typeof window !== 'undefined' ? `${window.location.origin}/auth/callback` : undefined);

      const res = await cfg.fetch(`${cfg.url}/auth/v1/otp`, {
        method: 'POST',
        headers: {
          apikey: cfg.anonKey,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          email,
          create_user: options.shouldCreateUser !== false,
          /* Supabase needs the redirect URL passed as `email_redirect_to` and
             the same URL also configured in the project's allow-list. */
          ...(emailRedirectTo ? { email_redirect_to: emailRedirectTo } : {}),
        }),
      });

      if (!res.ok) {
        const body = await res.text().catch(() => '');
        throw new Error(`[uh/auth] OTP request failed (${res.status}): ${body}`);
      }
      return { data: { email }, error: null };
    },

    /**
     * Complete a magic-link sign-in.
     *   verifyOtp({ token_hash, type: 'magiclink' })
     * On success, persists the session and notifies listeners.
     */
    async verifyOtp({ token_hash, type = 'magiclink', email }) {
      if (!token_hash) throw new Error('[uh/auth] verifyOtp requires { token_hash }');

      const res = await cfg.fetch(`${cfg.url}/auth/v1/verify`, {
        method: 'POST',
        headers: {
          apikey: cfg.anonKey,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ token_hash, type, ...(email ? { email } : {}) }),
      });

      if (!res.ok) {
        const body = await res.text().catch(() => '');
        throw new Error(`[uh/auth] verifyOtp failed (${res.status}): ${body}`);
      }

      const session = await res.json();
      saveSession(session);
      return { data: { session, user: session.user }, error: null };
    },

    /**
     * Return the current session, transparently refreshing if it's within
     * REFRESH_LEAD_SECONDS of expiry. Returns null if no session.
     */
    async getSession() {
      let session = loadSession();
      if (!session) return { data: { session: null }, error: null };

      const nowSec = Math.floor(Date.now() / 1000);
      if (session.expires_at && session.expires_at - nowSec < REFRESH_LEAD_SECONDS) {
        try { session = await auth.refreshSession(); } catch { session = null; }
      }
      return { data: { session }, error: null };
    },

    /** Returns the user record for the current session, or null. */
    async getUser() {
      const { data: { session } } = await auth.getSession();
      if (!session) return { data: { user: null }, error: null };

      const res = await cfg.fetch(`${cfg.url}/auth/v1/user`, {
        headers: {
          apikey: cfg.anonKey,
          Authorization: `Bearer ${session.access_token}`,
        },
      });
      if (!res.ok) {
        const body = await res.text().catch(() => '');
        return { data: { user: null }, error: new Error(body) };
      }
      const user = await res.json();
      return { data: { user }, error: null };
    },

    /**
     * Use the stored refresh_token to mint a new access_token.
     * Concurrent callers share one in-flight request so we don't burn
     * the refresh token on parallel calls.
     */
    async refreshSession() {
      if (inflightRefresh) return inflightRefresh;

      inflightRefresh = (async () => {
        const session = loadSession();
        if (!session || !session.refresh_token) throw new Error('[uh/auth] no session to refresh');

        const res = await cfg.fetch(`${cfg.url}/auth/v1/token?grant_type=refresh_token`, {
          method: 'POST',
          headers: {
            apikey: cfg.anonKey,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ refresh_token: session.refresh_token }),
        });

        if (!res.ok) {
          /* Refresh failed: token was revoked, expired beyond grace, or
             project keys rotated. Wipe local state — caller must re-auth. */
          saveSession(null);
          const body = await res.text().catch(() => '');
          throw new Error(`[uh/auth] refresh failed (${res.status}): ${body}`);
        }

        const fresh = await res.json();
        saveSession(fresh);
        emit('TOKEN_REFRESHED', fresh);
        return fresh;
      })().finally(() => { inflightRefresh = null; });

      return inflightRefresh;
    },

    /** Wipe the session locally AND tell Supabase to revoke the refresh token. */
    async signOut() {
      const session = loadSession();
      if (session) {
        /* Best effort — server-side revoke. Local wipe runs regardless. */
        cfg.fetch(`${cfg.url}/auth/v1/logout`, {
          method: 'POST',
          headers: {
            apikey: cfg.anonKey,
            Authorization: `Bearer ${session.access_token}`,
          },
        }).catch(() => {});
      }
      saveSession(null);
      return { error: null };
    },

    /**
     * Subscribe to auth events. Returns an unsubscribe function.
     * Events: 'SIGNED_IN' | 'SIGNED_OUT' | 'TOKEN_REFRESHED'.
     */
    onAuthStateChange(handler) {
      listeners.add(handler);
      /* Fire once with current state so consumers don't need a separate
         initial getSession() call. */
      const session = loadSession();
      if (session) Promise.resolve().then(() => handler('SIGNED_IN', session));
      return { unsubscribe: () => listeners.delete(handler) };
    },

    /** Intentional dead-end. The product spec forbids passwords. */
    signInWithPassword() {
      throw new Error(
        '[uh/auth] signInWithPassword is disabled. The Union Hub uses ' +
        'magic-link auth only. Use signInWithOtp({ email }).'
      );
    },

    /* Internal — read by tableQuery() to attach Bearer token. */
    _getAccessToken() {
      const s = loadSession();
      return s ? s.access_token : null;
    },
  };

  /* If we boot with an existing session, schedule a refresh immediately. */
  scheduleRefresh(loadSession());

  return auth;
}


/* ════════════════════════════════════════════════════════════════════════
   3 · DATA ACCESS
   ════════════════════════════════════════════════════════════════════════ */

function buildHeaders(cfg, auth, extras = {}) {
  const accessToken = auth ? auth._getAccessToken() : null;
  const h = {
    apikey: cfg.anonKey,
    /* If the user is signed in, RLS evaluates auth.uid() against their JWT.
       If not, we send the anon key as bearer — RLS sees an anon role. */
    Authorization: 'Bearer ' + (accessToken || cfg.anonKey),
    'Content-Type': 'application/json',
    Prefer: 'return=representation',
  };
  if (cfg.tenantId)   h['x-tenant-id']   = cfg.tenantId;
  if (cfg.tenantSlug) h['x-tenant-slug'] = cfg.tenantSlug;
  return Object.assign(h, extras);
}

function tableQuery(cfg, auth, table) {
  const params = new URLSearchParams();
  let _select = '*';
  let _single = false;
  let _method = 'GET';
  let _body   = null;

  const api = {
    select(cols = '*') { _select = cols; return api; },
    eq(col, val)       { params.append(col, 'eq.' + val); return api; },
    neq(col, val)      { params.append(col, 'neq.' + val); return api; },
    in(col, vals)      { params.append(col, 'in.(' + vals.join(',') + ')'); return api; },
    gt(col, val)       { params.append(col, 'gt.' + val); return api; },
    lt(col, val)       { params.append(col, 'lt.' + val); return api; },
    limit(n)           { params.set('limit', String(n)); return api; },
    order(col, opts)   {
      const dir = opts && opts.ascending === false ? 'desc' : 'asc';
      params.set('order', col + '.' + dir);
      return api;
    },
    single()           { _single = true; return api; },

    insert(rows)       { _method = 'POST';   _body = JSON.stringify(rows); return api; },
    update(patch)      { _method = 'PATCH';  _body = JSON.stringify(patch); return api; },
    delete()           { _method = 'DELETE'; return api; },

    async exec() {
      params.set('select', _select);
      const url = `${cfg.url}/rest/v1/${table}?${params.toString()}`;
      const headers = buildHeaders(
        cfg, auth,
        _single ? { Accept: 'application/vnd.pgrst.object+json' } : {}
      );
      const init = { method: _method, headers };
      if (_body) init.body = _body;

      let res = await cfg.fetch(url, init);

      /* If we got 401 and we DO have a session, try one refresh + retry. */
      if (res.status === 401 && auth && auth._getAccessToken()) {
        try {
          await auth.refreshSession();
          init.headers = buildHeaders(cfg, auth,
            _single ? { Accept: 'application/vnd.pgrst.object+json' } : {});
          res = await cfg.fetch(url, init);
        } catch { /* fall through to error below */ }
      }

      if (!res.ok) {
        const body = await res.text().catch(() => '');
        const err = new Error(`[uh/supabase] ${res.status} ${res.statusText} on ${table}: ${body}`);
        err.status = res.status;
        throw err;
      }
      const data = _method === 'DELETE' && res.status === 204
        ? null
        : await res.json();
      return { data, error: null };
    },

    then(onFulfilled, onRejected) { return api.exec().then(onFulfilled, onRejected); },
  };
  return api;
}


/* ════════════════════════════════════════════════════════════════════════
   4 · PUBLIC FACTORY
   ════════════════════════════════════════════════════════════════════════ */

export function createClient(overrides = {}) {
  const cfg  = resolveConfig(overrides);
  const auth = makeAuth(cfg);

  return {
    config: cfg,
    auth,

    from(table) { return tableQuery(cfg, auth, table); },

    /** Postgres RPC: client.rpc('fn_name', { arg: value }) */
    async rpc(fn, args = {}) {
      const res = await cfg.fetch(`${cfg.url}/rest/v1/rpc/${fn}`, {
        method: 'POST',
        headers: buildHeaders(cfg, auth),
        body: JSON.stringify(args),
      });
      if (!res.ok) {
        const body = await res.text().catch(() => '');
        const err = new Error(`[uh/supabase] rpc ${fn} ${res.status}: ${body}`);
        err.status = res.status;
        throw err;
      }
      return { data: await res.json(), error: null };
    },

    /** Direct REST escape hatch — for Storage, Edge Functions, anything raw. */
    async raw(path, init = {}) {
      const url = path.startsWith('http') ? path : cfg.url + path;
      const headers = buildHeaders(cfg, auth, init.headers || {});
      return cfg.fetch(url, Object.assign({}, init, { headers }));
    },

    /** Re-bind to a different tenant context (preserves auth/session). */
    withTenant({ tenantId, tenantSlug } = {}) {
      return createClient(Object.assign({}, overrides, {
        url: cfg.url,
        anonKey: cfg.anonKey,
        tenantId: tenantId || cfg.tenantId,
        tenantSlug: tenantSlug || cfg.tenantSlug,
      }));
    },
  };
}

export default createClient;
