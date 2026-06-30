/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/admin-intelligence.js
   Reader for the Workplace Intelligence dashboard.

   Single call to the admin-gated workplace_intelligence() RPC (migration 0021).
   Role-based access is enforced SERVER-SIDE: the RPC RAISES not_tenant_admin
   for non-admins, surfaced here as an Error whose .message is that code — the
   page maps it to an "Access denied" state.
   ────────────────────────────────────────────────────────────────────────── */

import createClient from '/lib/supabase.js';
import { getTenant } from '/lib/tenant.js';

/**
 * Fetch the aggregated dashboard payload for the trailing `days` window.
 * Returns { days, since, total, confirmed, by_topic[], by_worksite[] }.
 * Throws Error with .message in: no_tenant_context, not_tenant_admin,
 * not_authenticated, intel_failed.
 */
export async function fetchWorkplaceIntelligence(days = 30) {
  const tenant = await getTenant();
  if (!tenant) throw new Error('no_tenant_context');
  const client = createClient({ tenantId: tenant.id });   // x-tenant-id for the RPC's scope

  const res = await client.raw('/rest/v1/rpc/workplace_intelligence', {
    method: 'POST',
    body: JSON.stringify({ p_days: days }),
  });

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    let code = `intel_failed`;
    try { const p = JSON.parse(body); if (p.message) code = p.message; } catch { /* keep */ }
    const err = new Error(code);
    err.status = res.status;
    err.body   = body;
    throw err;
  }
  return res.json();
}

export default { fetchWorkplaceIntelligence };
