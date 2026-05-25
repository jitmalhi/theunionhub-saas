/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/admin-settings.js
   Tenant settings: read the current tenant row, save changes via the
   update_tenant_settings RPC (migration 0005).

   The RPC, not direct PATCH, is what makes saves work — RLS on
   public.tenants is read-only by design (see migration 0001), and the
   RPC is the only authenticated path to mutation. The RPC also checks
   the calling user's email matches contact_email, so unauthorised
   saves come back as not_tenant_admin rather than silently 403'ing
   under RLS.

   WCAG AA contrast validation is a client-side concern — this module
   doesn't enforce it; the settings.html page does, with the contrast
   formula inlined.
   ────────────────────────────────────────────────────────────────────────── */

import createClient from '/lib/supabase.js';
import { getTenant, clearCache as clearTenantCache } from '/lib/tenant.js';

/**
 * Return the current tenant row (re-fetches; doesn't trust the cached
 * lib/tenant.js copy because that one omits contact_email and similar
 * settings-relevant fields).
 */
export async function getTenantSettings() {
  const cached = await getTenant();
  if (!cached) throw new Error('[admin-settings] no tenant context');
  const client = createClient({ tenantId: cached.id });

  const params = new URLSearchParams();
  params.set('select', '*');
  params.append('slug', `eq.${cached.slug}`);
  params.set('limit', '1');

  const res = await client.raw(`/rest/v1/tenants?${params}`);
  if (!res.ok) throw new Error(`[admin-settings] fetch failed: ${res.status}`);
  const rows = await res.json();
  if (!rows[0]) throw new Error('[admin-settings] tenant row missing');
  return rows[0];
}

/**
 * Apply settings changes via the SECURITY DEFINER RPC.
 *
 *   await updateTenantSettings({ display_name: 'New', accent_hex: '#123456' })
 *
 * Pass only the fields you want changed; omitted / empty fields are
 * preserved server-side via COALESCE. Returns the updated tenant row.
 * Throws with the RPC's exception code in .message on failure:
 *   no_tenant_context | not_authenticated | not_tenant_admin
 */
export async function updateTenantSettings(patch = {}) {
  const cached = await getTenant();
  if (!cached) throw new Error('[admin-settings] no tenant context');
  const client = createClient({ tenantId: cached.id });

  // RPC param names mirror the function signature in migration 0010
  // (which extended 0005's four params with p_dues_cycle). Omitted /
  // null fields preserve the existing values server-side via COALESCE.
  const args = {
    p_display_name: patch.display_name ?? null,
    p_accent_hex:   patch.accent_hex   ?? null,
    p_local_number: patch.local_number ?? null,
    p_union_type:   patch.union_type   ?? null,
    p_dues_cycle:   patch.dues_cycle   ?? null,
  };

  const res = await client.raw('/rest/v1/rpc/update_tenant_settings', {
    method: 'POST',
    body: JSON.stringify(args),
  });

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    // PostgREST surfaces RAISE EXCEPTION text as JSON { code, message, hint }.
    let code = `http_${res.status}`;
    try {
      const parsed = JSON.parse(body);
      if (parsed.message) code = parsed.message;
    } catch { /* keep http_<status> */ }
    const err = new Error(code);
    err.status = res.status;
    err.body   = body;
    throw err;
  }

  // RPC returns the updated tenant row (function RETURNS public.tenants).
  // For RETURNS table-row, PostgREST returns the JSON object directly.
  const updated = await res.json();

  // The lib/tenant.js cache holds a subset of fields read at page load —
  // invalidate it so the next applyTenantTheme reflects the new accent.
  clearTenantCache();

  return updated;
}

export default { getTenantSettings, updateTenantSettings };
