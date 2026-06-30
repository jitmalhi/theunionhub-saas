/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/admin-grievances.js
   Grievance read/create for the admin app.

   All queries are tenant-scoped via the x-tenant-id header that
   lib/supabase.js attaches when given a tenantId. RLS on public.grievances
   (migration 0017, HARDENED) enforces isolation AND admin-only access
   server-side — this module trusts none of its own filtering.

   Mirrors lib/admin-members.js: a tenantClient() helper + the raw() escape
   hatch, and RPC error-code normalisation so the page can map codes to
   friendly text.
   ────────────────────────────────────────────────────────────────────────── */

import createClient from '/lib/supabase.js';
import { getTenant } from '/lib/tenant.js';

export const GRIEVANCE_STATUSES = ['Open', 'In Progress', 'Resolved'];

async function tenantClient() {
  const tenant = await getTenant();
  if (!tenant) throw new Error('no_tenant_context');
  return { tenant, client: createClient({ tenantId: tenant.id }) };
}

/* Lift a PostgREST error body into an Error whose .message is the RPC's
   RAISE EXCEPTION code (not_tenant_admin, no_tenant_context, …). Same shape as
   lib/admin-team.js / lib/admin-members.js. */
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
 * Verify the caller is a VERIFIED ADMIN of the current tenant.
 *
 * Needed because the 0017 grievance policies are admin-gated: a non-admin's
 * SELECT returns [] (indistinguishable from "no grievances"), so the UI can't
 * infer permission from an empty list. list_tenant_admins() (migration 0007)
 * RAISES not_tenant_admin for non-admins, giving us a definite signal.
 *
 * Resolves true on success (bootstrap-mode admins included — the RPC returns
 * an empty list but still 200s for a qualifying caller). Throws Error with
 * .message in: no_tenant_context, not_authenticated, not_tenant_admin,
 * admin_check_failed.
 */
export async function verifyTenantAdmin() {
  const { client } = await tenantClient();
  const res = await client.raw('/rest/v1/rpc/list_tenant_admins', {
    method: 'POST',
    body: '{}',
  });
  if (!res.ok) await throwForRpc(res, 'admin_check_failed');
  return true;
}

/**
 * List grievances for the current tenant (RLS-scoped + admin-gated).
 *
 *   await listGrievances()
 *   await listGrievances({ status: 'Open', sort: 'asc' })
 *
 * Returns an array of { id, member_name, grievance_type, status, description,
 * created_at }. Throws on transport failure.
 */
export async function listGrievances({ status = null, sort = 'desc' } = {}) {
  const { client } = await tenantClient();

  const params = new URLSearchParams();
  params.set('select', 'id,member_name,grievance_type,status,description,created_at');
  params.set('order',  `created_at.${sort === 'asc' ? 'asc' : 'desc'}`);
  if (status) params.append('status', `eq.${status}`);

  const res = await client.raw(`/rest/v1/grievances?${params.toString()}`);
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    const err = new Error('list_failed');
    err.status = res.status;
    err.body   = body;
    throw err;
  }
  return res.json();
}

/**
 * Create a grievance in the current tenant.
 *
 * tenant_id is set explicitly to satisfy the INSERT WITH CHECK
 * (tenant_id = get_request_tenant_id()); the 0017 HARDENED policy ALSO requires
 * the caller to be a tenant admin, so a non-admin INSERT is rejected by RLS
 * (surfaced here as a 4xx). Returns the created row.
 */
export async function createGrievance(input) {
  const { tenant, client } = await tenantClient();

  const member_name = (input.member_name || '').trim();
  if (!member_name) throw new Error('member_name_required');

  const status = GRIEVANCE_STATUSES.includes(input.status) ? input.status : 'Open';

  const body = {
    tenant_id:      tenant.id,                                   // RLS WITH CHECK
    member_name,
    grievance_type: (input.grievance_type || '').trim() || null,
    status,
    description:    (input.description || '').trim() || null,
  };

  const res = await client.raw('/rest/v1/grievances', {
    method: 'POST',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    const err = new Error('create_failed');
    err.status = res.status;
    err.body   = text;
    throw err;
  }
  const rows = await res.json();
  return Array.isArray(rows) ? rows[0] : rows;
}

export default { GRIEVANCE_STATUSES, verifyTenantAdmin, listGrievances, createGrievance };
