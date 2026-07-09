/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/admin-site.js
   CRUD for the Tier-1 public website (admin app).

   Same shape as lib/admin-members.js: every call is tenant-scoped via the
   x-tenant-id header lib/supabase.js attaches, and RLS (migrations 0036–0037)
   enforces admin-only writes server-side — this module trusts none of its own
   filtering. Loads the whole site in one call via the export_site() RPC (0039,
   admin-gated); writes go per table with the raw() escape hatch.
   ────────────────────────────────────────────────────────────────────────── */

import createClient from '/lib/supabase.js';
import { getTenant } from '/lib/tenant.js';

// Content tables the editor manages (besides the singleton site_settings).
export const SITE_TABLES = ['site_alerts', 'site_posts', 'site_officers', 'site_stewards', 'site_meetings', 'site_documents'];

async function tenantClient() {
  const tenant = await getTenant();
  if (!tenant) throw new Error('[admin-site] no tenant context');
  return { tenant, client: createClient({ tenantId: tenant.id }) };
}

/**
 * Load the whole site for editing (settings + all content incl drafts +
 * hostnames + files manifest). Uses export_site() so it's one admin-gated call.
 * Returns the bundle, or a minimal empty shell if the site has no settings yet.
 */
export async function loadSite() {
  const { client, tenant } = await tenantClient();
  const { data, error } = await client.rpc('export_site');
  if (error) throw error;
  const bundle = data || {};
  bundle.tenant   = bundle.tenant   || { id: tenant.id, slug: tenant.slug };
  bundle.settings = bundle.settings || null;
  for (const key of ['alerts', 'posts', 'officers', 'stewards', 'meetings', 'documents', 'hostnames', 'files']) {
    bundle[key] = Array.isArray(bundle[key]) ? bundle[key] : [];
  }
  return bundle;
}

/**
 * Upsert the singleton site_settings row for this tenant (one per tenant via
 * the UNIQUE(tenant_id) constraint). Pass any subset of columns.
 */
export async function saveSettings(patch) {
  const { client, tenant } = await tenantClient();
  const body = Object.assign({ tenant_id: tenant.id }, patch);
  const res = await client.raw('/rest/v1/site_settings?on_conflict=tenant_id', {
    method: 'POST',
    headers: { Prefer: 'resolution=merge-duplicates,return=representation' },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const t = await res.text().catch(() => '');
    throw new Error(`[admin-site] saveSettings failed: ${res.status} ${t}`);
  }
  const rows = await res.json();
  return rows[0] || null;
}

/** Publish / unpublish the site (its own action so the button is unambiguous). */
export async function setPublished(published) {
  return saveSettings({ published: !!published });
}

/* ── Generic per-item CRUD for the content tables ── */

function assertTable(table) {
  if (!SITE_TABLES.includes(table)) throw new Error(`[admin-site] refusing unknown table: ${table}`);
}

export async function createItem(table, row) {
  assertTable(table);
  const { client, tenant } = await tenantClient();
  const body = Object.assign({ tenant_id: tenant.id }, row);
  const res = await client.raw(`/rest/v1/${table}`, {
    method: 'POST',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`[admin-site] create ${table} failed: ${res.status} ${await res.text().catch(() => '')}`);
  const rows = await res.json();
  return rows[0] || null;
}

export async function updateItem(table, id, patch) {
  assertTable(table);
  const { client } = await tenantClient();
  // tenant_id is immutable from here — never let a patch move a row's tenant.
  const body = Object.assign({}, patch);
  delete body.tenant_id; delete body.id; delete body.created_at; delete body.updated_at;
  const res = await client.raw(`/rest/v1/${table}?id=eq.${encodeURIComponent(id)}`, {
    method: 'PATCH',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`[admin-site] update ${table} failed: ${res.status} ${await res.text().catch(() => '')}`);
  const rows = await res.json();
  return rows[0] || null;
}

export async function deleteItem(table, id) {
  assertTable(table);
  const { client } = await tenantClient();
  const res = await client.raw(`/rest/v1/${table}?id=eq.${encodeURIComponent(id)}`, { method: 'DELETE' });
  if (!res.ok && res.status !== 204) {
    throw new Error(`[admin-site] delete ${table} failed: ${res.status}`);
  }
  return true;
}

/**
 * Download the full site export as a JSON file (content-ownership). Uses the
 * same admin-gated export_site() the /api/site-export endpoint wraps.
 */
export async function downloadExport() {
  const { client, tenant } = await tenantClient();
  const { data, error } = await client.rpc('export_site');
  if (error) throw error;
  const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `${(tenant.slug || 'site')}-site-export.json`;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export default { loadSite, saveSettings, setPublished, createItem, updateItem, deleteItem, downloadExport, SITE_TABLES };
