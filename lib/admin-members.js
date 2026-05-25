/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/admin-members.js
   Member CRUD for the admin app.

   All queries are tenant-scoped via the x-tenant-id header that
   lib/supabase.js attaches when given a tenantId. RLS on public.members
   (from migration 0002) enforces isolation server-side; this module
   trusts none of its own filtering.

   Uses lib/supabase.js's raw() escape hatch for everything that needs
   PostgREST-only features (ilike for name search, count via
   Content-Range, embeds for joining related rows in one trip).
   ────────────────────────────────────────────────────────────────────────── */

import createClient from '/lib/supabase.js';
import { getTenant } from '/lib/tenant.js';

const DEFAULT_PAGE_SIZE = 25;

async function tenantClient() {
  const tenant = await getTenant();
  if (!tenant) throw new Error('[admin-members] no tenant context');
  return { tenant, client: createClient({ tenantId: tenant.id }) };
}

function parseContentRangeTotal(headerValue) {
  if (!headerValue) return 0;
  const m = headerValue.match(/\/(\d+)$/);
  return m ? parseInt(m[1], 10) : 0;
}

/**
 * List members with optional status filter, name search, and pagination.
 *
 *   await listMembers()
 *   await listMembers({ status: 'active' })
 *   await listMembers({ search: 'okonkwo', page: 2 })
 *
 * Returns { rows, total, page, pageSize, totalPages }.
 */
export async function listMembers({
  status = null,
  search = null,
  page   = 1,
  pageSize = DEFAULT_PAGE_SIZE,
} = {}) {
  const { client } = await tenantClient();

  const params = new URLSearchParams();
  params.set('select', 'id,full_name,status,member_since,union_name,local_number,created_at');
  params.set('order',  'full_name.asc,created_at.desc');

  if (status) params.append('status', `eq.${status}`);
  if (search && search.trim()) {
    // PostgREST ilike with wildcards: * → %. Escape any literal % the
    // user typed so it doesn't widen the search unexpectedly.
    const escaped = search.trim().replace(/%/g, '\\%').replace(/\*/g, '%');
    params.append('full_name', `ilike.%${escaped}%`);
  }

  const from = Math.max(0, (page - 1) * pageSize);
  const to   = from + pageSize - 1;

  const res = await client.raw(`/rest/v1/members?${params.toString()}`, {
    headers: {
      Prefer: 'count=exact',
      Range: `${from}-${to}`,
      'Range-Unit': 'items',
    },
  });

  if (!res.ok) {
    // 206 Partial Content is the success path for ranged requests; 416
    // means page out of range (treat as empty).
    if (res.status === 416) {
      return { rows: [], total: 0, page, pageSize, totalPages: 0 };
    }
    throw new Error(`[admin-members] list failed: ${res.status}`);
  }

  const rows  = await res.json();
  const total = parseContentRangeTotal(res.headers.get('content-range'));
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  return { rows, total, page, pageSize, totalPages };
}

/**
 * Count members per status. Returns { active, inactive, suspended,
 * pending, total }. Used by the filter chips so each chip can show its
 * own count next to the label.
 */
export async function countByStatus() {
  const { client } = await tenantClient();

  async function countWhere(filter) {
    const params = new URLSearchParams();
    params.set('select', 'id');
    params.set('limit',  '0');
    if (filter) params.append(filter.col, filter.op);
    const res = await client.raw(`/rest/v1/members?${params}`, {
      headers: { Prefer: 'count=exact' },
    });
    if (!res.ok) return 0;
    return parseContentRangeTotal(res.headers.get('content-range'));
  }

  const [active, inactive, suspended, pending, total] = await Promise.all([
    countWhere({ col: 'status', op: 'eq.active' }),
    countWhere({ col: 'status', op: 'eq.inactive' }),
    countWhere({ col: 'status', op: 'eq.suspended' }),
    countWhere({ col: 'status', op: 'eq.pending' }),
    countWhere(null),
  ]);
  return { active, inactive, suspended, pending, total };
}

/**
 * Fetch a single member by id. RLS scopes to current tenant.
 * Returns null if not found (or not visible from the current tenant).
 */
export async function getMember(id) {
  const { client } = await tenantClient();
  const params = new URLSearchParams();
  params.set('select', '*');
  params.append('id', `eq.${id}`);
  params.set('limit', '1');

  const res = await client.raw(`/rest/v1/members?${params}`);
  if (!res.ok) return null;
  const rows = await res.json();
  return rows[0] || null;
}

/**
 * Update mutable fields on a member. Anon role can do this via RLS too,
 * but the admin UI calls it after requireAuth(). Returns the updated row.
 */
export async function updateMember(id, patch) {
  const { client } = await tenantClient();
  const allowed = ['full_name', 'status'];
  const body = {};
  for (const k of allowed) if (patch[k] !== undefined) body[k] = patch[k];

  const params = new URLSearchParams();
  params.append('id', `eq.${id}`);

  const res = await client.raw(`/rest/v1/members?${params}`, {
    method: 'PATCH',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`[admin-members] update failed: ${res.status} ${text}`);
  }
  const rows = await res.json();
  return rows[0] || null;
}

/**
 * Recent verifications + dues collections for a single member, joined
 * for use on the member detail page. Two concurrent fetches.
 */
export async function getMemberHistory(id, { limit = 10 } = {}) {
  const { client } = await tenantClient();

  const verifsUrl =
    `/rest/v1/verifications?select=id,result,created_at` +
    `&member_id=eq.${id}&order=created_at.desc&limit=${limit}`;
  const duesUrl =
    `/rest/v1/dues_collections?select=id,collected_at,collection_date,collected_by` +
    `&member_id=eq.${id}&order=collected_at.desc&limit=${limit}`;

  const [verifsRes, duesRes] = await Promise.all([
    client.raw(verifsUrl),
    client.raw(duesUrl),
  ]);

  const verifications    = verifsRes.ok ? await verifsRes.json() : [];
  const duesCollections  = duesRes.ok   ? await duesRes.json()   : [];
  return { verifications, duesCollections };
}

/**
 * Lift PostgREST error body into a tidy Error whose .message is the
 * RPC's RAISE EXCEPTION code (no_tenant_context, not_tenant_admin,
 * full_name_required, …). Same pattern as lib/admin-team.js.
 */
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
 * Create a single new member via the admin_add_member RPC (migration 0009).
 *
 *   await createMember({ full_name: 'Jane Doe', status: 'active', member_since: '2020-01-15' })
 *
 * Returns the new member row. Raises with .message in:
 *   no_tenant_context, not_authenticated, not_tenant_admin, full_name_required
 */
export async function createMember(input) {
  const { client } = await tenantClient();
  const res = await client.raw('/rest/v1/rpc/admin_add_member', {
    method: 'POST',
    body: JSON.stringify({
      p_full_name:    input.full_name,
      p_status:       input.status       || 'active',
      p_member_since: input.member_since || null,
      p_union_name:   input.union_name   || null,
      p_local_number: input.local_number || null,
    }),
  });
  if (!res.ok) await throwForRpc(res, 'create_failed');
  // RETURNS public.members — PostgREST sends the row object directly.
  return res.json();
}

/**
 * Bulk-insert up to 1000 member rows via admin_add_members_bulk.
 * Each row is wrapped in a server-side savepoint, so individual
 * failures don't roll back the rest.
 *
 * Returns the per-row result table:
 *   [{ row_index, success, member_id, error_code }, …]
 *
 * The row_index is zero-based within the batch — the caller is
 * responsible for mapping back to CSV row numbers if it split.
 */
export async function bulkImportMembers(rows) {
  if (!Array.isArray(rows) || rows.length === 0) return [];
  const { client } = await tenantClient();
  const res = await client.raw('/rest/v1/rpc/admin_add_members_bulk', {
    method: 'POST',
    body: JSON.stringify({ p_members: rows }),
  });
  if (!res.ok) await throwForRpc(res, 'bulk_failed');
  return res.json();
}

/**
 * Chunk a long member array into safe-sized batches (default 500),
 * call bulkImportMembers on each, stitch the per-row results back
 * together with global indices, and emit progress updates.
 *
 *   await importInBatches(rows, {
 *     batchSize: 500,
 *     onProgress: (done, total) => …,
 *   });
 *
 * Returns the full combined result array. row_index in the returned
 * objects is GLOBAL (matches the original csvRows index), not the
 * per-batch index the RPC returned.
 */
export async function importInBatches(rows, { batchSize = 500, onProgress } = {}) {
  const all = [];
  for (let i = 0; i < rows.length; i += batchSize) {
    const batch = rows.slice(i, i + batchSize);
    const results = await bulkImportMembers(batch);
    for (const r of results) {
      all.push({ ...r, row_index: r.row_index + i });
    }
    if (typeof onProgress === 'function') {
      onProgress(Math.min(i + batchSize, rows.length), rows.length);
    }
  }
  return all;
}

export default {
  listMembers,
  countByStatus,
  getMember,
  updateMember,
  getMemberHistory,
  createMember,
  bulkImportMembers,
  importInBatches,
};
