/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/admin-audit.js
   Paginated reader for public.audit_log + helpers for the filter UI.

   RLS on audit_log (migration 0004) requires the authenticated role, so
   this module is unusable from anon — and that's correct. Pages calling
   it MUST be gated by lib/auth-guard.js requireAuth() first.

   The detail jsonb column is opaque to this module — the page renders
   it however it wants (current pattern: collapsed JSON.stringify with a
   click-to-expand later).
   ────────────────────────────────────────────────────────────────────────── */

import createClient from '/lib/supabase.js';
import { getTenant } from '/lib/tenant.js';

const DEFAULT_PAGE_SIZE = 50;
const ACTIONS_SAMPLE_LIMIT = 500;  // rows scanned to derive the distinct-action dropdown

function parseContentRangeTotal(headerValue) {
  if (!headerValue) return 0;
  const m = headerValue.match(/\/(\d+)$/);
  return m ? parseInt(m[1], 10) : 0;
}

async function tenantClient() {
  const tenant = await getTenant();
  if (!tenant) throw new Error('[admin-audit] no tenant context');
  return createClient({ tenantId: tenant.id });
}

/**
 * List audit log rows, newest first, paginated, optionally filtered.
 *
 *   await listAuditLog()
 *   await listAuditLog({ page: 2 })
 *   await listAuditLog({ action: 'tenant_settings_updated' })
 *   await listAuditLog({ actor: 'user:abc' })   // substring match on actor
 *
 * Returns { rows, total, page, pageSize, totalPages }.
 */
export async function listAuditLog({
  action   = null,
  actor    = null,
  page     = 1,
  pageSize = DEFAULT_PAGE_SIZE,
} = {}) {
  const client = await tenantClient();

  const params = new URLSearchParams();
  params.set('select', 'id,actor,action,target_type,target_id,detail,created_at');
  params.set('order',  'created_at.desc');

  if (action) params.append('action', `eq.${action}`);

  // Actor is a substring match: 'user:abc' matches 'user:abc123…',
  // 'system' matches 'system:new-tenant.mjs'. PostgREST uses % as the
  // wildcard for ilike; * is a UX-friendly alias the caller might type.
  if (actor && actor.trim()) {
    const escaped = actor.trim().replace(/%/g, '\\%').replace(/\*/g, '%');
    params.append('actor', `ilike.%${escaped}%`);
  }

  const from = Math.max(0, (page - 1) * pageSize);
  const to   = from + pageSize - 1;

  const res = await client.raw(`/rest/v1/audit_log?${params}`, {
    headers: {
      Prefer: 'count=exact',
      Range: `${from}-${to}`,
      'Range-Unit': 'items',
    },
  });

  if (!res.ok) {
    if (res.status === 416) {
      return { rows: [], total: 0, page, pageSize, totalPages: 0 };
    }
    // 401/403: caller forgot to gate with requireAuth(); 404: table
    // missing (shouldn't happen post-0004). Either way, fail loudly.
    throw new Error(`[admin-audit] list failed: ${res.status}`);
  }

  const rows  = await res.json();
  const total = parseContentRangeTotal(res.headers.get('content-range'));
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  return { rows, total, page, pageSize, totalPages };
}

/**
 * Distinct action values present in the tenant's audit_log. Used by the
 * audit page to populate its action <select> from real data rather than
 * a hardcoded list.
 *
 * Strategy: fetch the action column from the N most recent rows (where N
 * is ACTIONS_SAMPLE_LIMIT) and de-dup client-side. Cheaper than a
 * server-side SELECT DISTINCT on a large table, and the recent rows are
 * the actions the admin cares about anyway. Stale entries surface
 * eventually as they cycle into the sample.
 *
 * For a tenant with high audit volume and a stable action vocabulary,
 * this is fine. If the action set ever needs to be exhaustive, swap to
 * a SECURITY DEFINER RPC that does SELECT DISTINCT server-side.
 */
export async function getDistinctActions() {
  const client = await tenantClient();
  const params = new URLSearchParams();
  params.set('select', 'action');
  params.set('order',  'created_at.desc');
  params.set('limit',  String(ACTIONS_SAMPLE_LIMIT));

  const res = await client.raw(`/rest/v1/audit_log?${params}`);
  if (!res.ok) return [];
  const rows = await res.json();

  const seen = new Set();
  for (const r of rows) if (r.action) seen.add(r.action);
  return [...seen].sort();
}

export default { listAuditLog, getDistinctActions };
