/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/admin-team.js
   Wrappers for the three tenant_admins RPCs (migrations 0006 + 0007):

     listTeamAdmins()        → public.list_tenant_admins()
     addTeamAdmin(email)     → public.add_tenant_admin(p_email)
     removeTeamAdmin(userId) → public.remove_tenant_admin(p_user_id)

   The RPCs themselves enforce the security model — caller must be a
   tenant admin (explicit row OR bootstrap fallback). This module is
   just a thin convenience layer + error-code normalisation: every
   thrown Error has the raw exception code in .message so the page can
   map to friendly text without parsing JSON twice.
   ────────────────────────────────────────────────────────────────────────── */

import createClient from '/lib/supabase.js';
import { getTenant } from '/lib/tenant.js';

async function tenantClient() {
  const tenant = await getTenant();
  if (!tenant) throw new Error('[admin-team] no tenant context');
  return createClient({ tenantId: tenant.id });
}

/** Lift the PostgREST error body into a tidy Error whose .message is the
 *  RPC's RAISE EXCEPTION code (no_tenant_context, not_tenant_admin, …). */
async function throwForRpc(res, fallback) {
  const body = await res.text().catch(() => '');
  let code = fallback || `http_${res.status}`;
  try {
    const parsed = JSON.parse(body);
    if (parsed.message) code = parsed.message;
  } catch { /* keep fallback */ }
  const err = new Error(code);
  err.status = res.status;
  err.body   = body;
  throw err;
}

/**
 * Returns the explicit admin rows for the current tenant.
 * Zero rows is a valid bootstrap state — the page should detect that
 * and surface the bootstrap-mode banner.
 */
export async function listTeamAdmins() {
  const client = await tenantClient();
  const res = await client.raw('/rest/v1/rpc/list_tenant_admins', {
    method: 'POST',
    body: '{}',
  });
  if (!res.ok) await throwForRpc(res, 'list_failed');
  const rows = await res.json();
  return Array.isArray(rows) ? rows : [];
}

/**
 * Invite an existing auth.users entry by email. The migration's
 * add_tenant_admin auto-promotes the caller if they qualify via
 * bootstrap; no special handling needed here.
 *
 * Raises with .message in:
 *   no_tenant_context, not_authenticated, not_tenant_admin,
 *   invalid_email, user_not_signed_in_yet
 */
export async function addTeamAdmin(email) {
  const client = await tenantClient();
  const res = await client.raw('/rest/v1/rpc/add_tenant_admin', {
    method: 'POST',
    body: JSON.stringify({ p_email: email }),
  });
  if (!res.ok) await throwForRpc(res, 'add_failed');
  return res.json();
}

/**
 * Remove an admin by user_id. The migration refuses the request if it
 * would leave the tenant with zero admins; we surface that as
 * cannot_remove_last_admin in the thrown Error.
 */
export async function removeTeamAdmin(userId) {
  const client = await tenantClient();
  const res = await client.raw('/rest/v1/rpc/remove_tenant_admin', {
    method: 'POST',
    body: JSON.stringify({ p_user_id: userId }),
  });
  if (!res.ok) await throwForRpc(res, 'remove_failed');
  // RPC returns void; PostgREST sends an empty body for that.
  return true;
}

export default { listTeamAdmins, addTeamAdmin, removeTeamAdmin };
