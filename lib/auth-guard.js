/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/auth-guard.js
   Session gate for protected admin pages.

   Every page under /admin/* (except /admin/signin and /admin/callback)
   imports this and calls requireAuth() at the top of its boot. If no
   session is present, the page redirects to /admin/signin?next=<orig>
   before any rendering happens — no flash of admin content for an
   unauthenticated visitor.

   This is a CLIENT-side guard. It's enough because every protected
   query also goes through RLS on Supabase: even if a hostile script
   bypassed requireAuth() in the browser, the database would reject
   the query without a valid auth.uid(). The guard is UX, not security.
   ────────────────────────────────────────────────────────────────────────── */

import createClient from '/lib/supabase.js';

const SIGNIN_PATH    = '/admin/signin';
const POSTLOGIN_PARAM = 'next';

/* ─── DEV-ONLY BYPASS ─────────────────────────────────────────────────
   On *.localhost hostnames, skip the magic-link gate and synthesise a
   placeholder session so the admin UI shell can render without going
   through sign-in. Strict gating: location.hostname must END with
   ".localhost". Apex localhost (no subdomain) does not match — and
   apex doesn't route to /admin/* anyway. Production hosts
   (*.theunionhub.com) never match by construction.

   The synthesised session has a fake access_token. Supabase REST
   queries (members, dues, audit) will still 401 against a real
   project — this bypass unblocks page rendering and UI iteration,
   not data fetching. For full local function, also configure
   SUPABASE_URL + SUPABASE_ANON_KEY in .env.local and seed a tenant
   row matching the subdomain slug.

   NEVER widen the gate to allow more hosts. The whole point is that
   it's impossible to ship a build where this fires on a real domain. */
const DEV_BYPASS_SESSION = Object.freeze({
  access_token:  'dev-bypass-not-a-real-token',
  refresh_token: 'dev-bypass-not-a-real-token',
  expires_in:    3600,
  user: Object.freeze({
    id:    '00000000-0000-0000-0000-000000000000',
    email: 'dev@local.invalid',
    aud:   'authenticated',
    role:  'authenticated',
  }),
});

function isDevBypassHost() {
  return typeof location !== 'undefined'
      && typeof location.hostname === 'string'
      && location.hostname.endsWith('.localhost');
}

let _devBypassWarned = false;
function devBypassSession() {
  if (!isDevBypassHost()) return null;
  if (!_devBypassWarned) {
    _devBypassWarned = true;
    console.warn(
      '[uh/auth-guard] DEV BYPASS active — *.localhost host detected. ' +
      'Admin shell renders without a real session; Supabase queries ' +
      'will still 401. Production hosts never trigger this.'
    );
  }
  return DEV_BYPASS_SESSION;
}

/**
 * Block rendering until a session is confirmed. Redirects to /admin/signin
 * (preserving where the user was trying to go) when no session exists.
 *
 *   const session = await requireAuth();
 *   if (!session) return;  // page is unmounting; abort boot
 *
 * Returns the session object on success, null on the redirect path.
 */
export async function requireAuth() {
  const bypass = devBypassSession();
  if (bypass) return bypass;

  const supabase = createClient();
  const { data: { session } } = await supabase.auth.getSession();

  if (!session) {
    const next = encodeURIComponent(location.pathname + location.search);
    location.replace(`${SIGNIN_PATH}?${POSTLOGIN_PARAM}=${next}`);
    return null;
  }
  return session;
}

/**
 * Subscribe to auth state changes. Default behaviour: on SIGNED_OUT,
 * redirect to /admin/signin so a multi-tab sign-out propagates cleanly.
 * Pass a handler for custom reactions (e.g. updating the email shown
 * in the nav bar after TOKEN_REFRESHED).
 *
 *   const stop = watchAuth((event, session) => { … });
 *   // … later
 *   stop();
 */
export function watchAuth(handler) {
  /* On dev bypass there is no real auth stream to subscribe to.
     Return a no-op unsubscribe so callers can still tear down. */
  if (isDevBypassHost()) return () => {};

  const supabase = createClient();
  const { unsubscribe } = supabase.auth.onAuthStateChange((event, session) => {
    if (event === 'SIGNED_OUT' && location.pathname !== SIGNIN_PATH) {
      location.replace(SIGNIN_PATH);
      return;
    }
    if (typeof handler === 'function') {
      try { handler(event, session); } catch { /* never let a handler break the guard */ }
    }
  });
  return unsubscribe;
}

/**
 * Sign out the current user. The onAuthStateChange listener installed
 * by watchAuth() handles the redirect; callers don't need to navigate.
 */
export async function signOut() {
  const supabase = createClient();
  await supabase.auth.signOut();
}

export default { requireAuth, watchAuth, signOut, SIGNIN_PATH };
