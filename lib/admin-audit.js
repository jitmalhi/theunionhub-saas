/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/admin-audit.js
   Paginated reader for public.audit_log.

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

function parseContentRangeTotal(headerValue) {
  if (!headerValue) return 0;
  const m = headerValue.match(/\/(\d+)$/);
  return m ? parseInt(m[1], 10) : 0;
}

/**
 * List audit log rows, newest first, paginated.
 *
 *   await listAuditLog()
 *   await listAuditLog({ page: 2 })
 *   await listAuditLog({ action: 'tenant_settings_updated' })
 *
 * Returns { rows, total, page, pageSize, totalPages }.
 */
export async function listAuditLog({
  action = null,
  page   = 1,
  pageSize = DEFAULT_PAGE_SIZE,
} = {}) {
  const tenant = await getTenant();
  if (!tenant) throw new Error('[admin-audit] no tenant context');
  const client = createClient({ tenantId: tenant.id });

  const params = new URLSearchParams();
  params.set('select', 'id,actor,action,target_type,target_id,detail,created_at');
  params.set('order',  'created_at.desc');
  if (action) params.append('action', `eq.${action}`);

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

export default { listAuditLog };
