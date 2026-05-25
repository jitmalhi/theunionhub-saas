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
