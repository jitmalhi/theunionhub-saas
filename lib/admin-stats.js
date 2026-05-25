/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/admin-stats.js
   Tenant-scoped dashboard data fetcher.

   Five concurrent fetches: members count, active-members count,
   verifications-today count, dues-today count, and the last 10
   verifications joined to member names. All queries pass through
   lib/supabase.js bound with the current tenantId, so the x-tenant-id
   header is set and RLS enforces tenant isolation server-side. We do
   not trust the count to come back filtered — that's the database's job.

   Counts use PostgREST's `Prefer: count=exact` header on a 0-row request:
   the response body is empty but the Content-Range header carries the
   total. Cheaper than fetching rows and counting client-side.
   ────────────────────────────────────────────────────────────────────────── */

import createClient from '/lib/supabase.js';
import { getTenant } from '/lib/tenant.js';

function todayStartIso() {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d.toISOString();
}

/**
 * Count rows in `table` (RLS-scoped) matching optional filters.
 *
 *   await countRows(client, 'members')
 *   await countRows(client, 'members', [{ col: 'status', op: 'eq.active' }])
 *
 * Filters are PostgREST-style (col=op.value). The function adds limit=0
 * + Prefer: count=exact, then parses Content-Range. Returns 0 on any
 * non-2xx — the dashboard shows zeroes for missing data rather than
 * crashing.
 */
async function countRows(client, table, filters = []) {
  const params = new URLSearchParams();
  params.set('select', 'id');
  params.set('limit', '0');
  for (const f of filters) params.append(f.col, f.op);

  const res = await client.raw(`/rest/v1/${table}?${params.toString()}`, {
    method: 'GET',
    headers: { Prefer: 'count=exact' },
  });
  if (!res.ok) return 0;
  const range = res.headers.get('content-range') || '';
  const m = range.match(/\/(\d+)$/);
  return m ? parseInt(m[1], 10) : 0;
}

/**
 * Last N verifications with the member's name embedded via the
 * verifications.member_id → members.id FK relationship. PostgREST
 * resolves the embed because the FK exists; if it ever stops working,
 * the tilted symptom will be the .members field coming back as null,
 * which the dashboard renders as "—".
 */
async function recentVerifications(client, limit = 10) {
  const url =
    `/rest/v1/verifications` +
    `?select=id,result,created_at,member_id,members(full_name,status)` +
    `&order=created_at.desc&limit=${limit}`;
  const res = await client.raw(url);
  if (!res.ok) return [];
  return res.json();
}

/**
 * One-shot dashboard fetch. Five concurrent queries; aggregate result.
 * Throws if no tenant context (the page should redirect to /admin/signin
 * before reaching here).
 */
export async function getDashboardData() {
  const tenant = await getTenant();
  if (!tenant) throw new Error('[admin-stats] no tenant context resolved');

  const client = createClient({ tenantId: tenant.id });
  const todayIso = todayStartIso();

  const [members, activeMembers, verifsToday, duesToday, recent] = await Promise.all([
    countRows(client, 'members'),
    countRows(client, 'members',          [{ col: 'status',       op: 'eq.active' }]),
    countRows(client, 'verifications',    [{ col: 'created_at',   op: `gte.${todayIso}` }]),
    countRows(client, 'dues_collections', [{ col: 'collected_at', op: `gte.${todayIso}` }]),
    recentVerifications(client, 10),
  ]);

  return {
    tenant,
    counts: { members, activeMembers, verifsToday, duesToday },
    recent,
  };
}

export default { getDashboardData };
