/* ──────────────────────────────────────────────────────────────────────────
   lib/member-fetch.js
   Dual-backend member fetch shared by /card and /verify.

   Harvested from member-id-system's members.js (the LIVE-vs-DEMO split), so
   both pages get a clean demo mode that NEVER touches tenant data — and so the
   identical inline fetchMemberById()/sbHeaders() that were duplicated in
   card.html and verify.html live in exactly one place.

   Two backends, same shape:
     · LIVE  — ?id=<uuid> present → single-row lookup via the tenant-scoped
               lookup_member RPC (SECURITY DEFINER; migrations 0008 + 0033).
     · DEMO  — no ?id= → the canonical demo-cast member below. Demo mode issues
               no Supabase request at all.

   The returned member shape (public-safe, whitelisted by lookup_member):
     { id, member_number, full_name, union_name, local_number, member_since, status }
   ────────────────────────────────────────────────────────────────────────── */

import { resolveConfig } from '/lib/supabase.js';

const { url: SUPABASE_URL, anonKey: SUPABASE_KEY } = resolveConfig();

/* Canonical demo cast (MOCKUP-RULES governs demo states inside the live
   product; only real tenant data is exempt). Jordan Rivera anchors the
   membership story; Local 412 is the fictional local; M-100823 is his card
   number. On a resolved tenant subdomain, applyTenantToMember() in the page
   overlays the tenant's display_name / local_number — both fictional — so no
   real union name ever appears. */
export const DEMO_MEMBER = Object.freeze({
  id: '550bc413-53db-4f83-98e4-7c5c44d721d0',
  member_number: 'M-100823',
  full_name: 'Jordan Rivera',
  union_name: 'Healthcare Workers Union',
  local_number: '412',
  member_since: '2019-04-12',
  status: 'active',
});

/* Supabase REST headers, tenant-scoped. tenantId is threaded from the page
   (set after lib/tenant.js resolves) so post-0002 RLS sees x-tenant-id. */
export function sbHeaders(tenantId, extra) {
  const h = {
    apikey: SUPABASE_KEY,
    Authorization: `Bearer ${SUPABASE_KEY}`,
  };
  if (tenantId) h['x-tenant-id'] = tenantId;
  if (extra) Object.assign(h, extra);
  return h;
}

/* LIVE single-row lookup. Returns the member row, or null on miss / error.
   Goes through lookup_member because anon has no direct SELECT on members
   after migration 0008. */
export async function fetchMemberById(id, tenantId) {
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/lookup_member`, {
      method: 'POST',
      headers: sbHeaders(tenantId, { 'Content-Type': 'application/json' }),
      body: JSON.stringify({ p_id: id }),
    });
    if (!res.ok) return null;
    const rows = await res.json();
    return (Array.isArray(rows) ? rows[0] : rows) || null;
  } catch {
    return null;
  }
}
