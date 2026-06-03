/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/admin-logo.js
   Upload / replace / remove the tenant logo.

   Two-step flow:
     1. uploadLogo(file)  →  uploads bytes to Supabase Storage at
                            <tenant_id>/logo.<ext>, returns the public URL
                            (with a cache-buster query string).
     2. setLogoUrl(url)   →  calls public.set_tenant_logo(p_url) RPC to
                            persist the URL on the tenants row.
                            Audit row written by the RPC.

   removeLogo() bundles both: best-effort delete the Storage object(s)
   under <tenant_id>/, then call setLogoUrl(null).

   The RPC + Storage RLS (migration 0011) together enforce admin-only
   writes; this module is a thin convenience layer with friendly
   error mapping.
   ────────────────────────────────────────────────────────────────────────── */

import createClient, { resolveConfig } from '/lib/supabase.js';
import { getTenant, clearCache as clearTenantCache } from '/lib/tenant.js';

const BUCKET    = 'tenant-assets';
const MAX_BYTES = 5 * 1024 * 1024;   // mirror of storage.buckets.file_size_limit

// MIME → extension. The Storage bucket's allowed_mime_types must list
// each of these; if either side drops one, the upload fails at Storage
// with a clear error and the client surfaces 'unsupported_mime'.
const MIME_TO_EXT = {
  'image/png':     'png',
  'image/jpeg':    'jpg',
  'image/svg+xml': 'svg',
  'image/webp':    'webp',
};
const EXTS = Object.values(MIME_TO_EXT);

function cfg() {
  // Sourced from the central runtime config in /lib/supabase.js — no longer
  // depends on a page-injected window.__UH_CONFIG__ block. Return shape is
  // preserved (.SUPABASE_URL / .SUPABASE_ANON_KEY) so callers are unchanged.
  const c = resolveConfig();
  return { SUPABASE_URL: c.url, SUPABASE_ANON_KEY: c.anonKey };
}

function publicUrlFor(supabaseUrl, path) {
  return `${supabaseUrl.replace(/\/+$/, '')}/storage/v1/object/public/${BUCKET}/${path}`;
}

async function getSessionOrThrow() {
  const supabase = createClient();
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) throw new Error('not_authenticated');
  return session;
}

/* ════════════════════════════════════════════════════════════════════════
   Storage helpers
   ════════════════════════════════════════════════════════════════════════ */

/** Delete <tenant_id>/logo.{png,jpg,svg,webp} from Storage. Best-effort;
 *  failures are swallowed because we always want to fall through to the
 *  RPC update. */
async function deleteAllLogoFiles(tenantId, session) {
  const c = cfg();
  await Promise.all(
    EXTS.map((ext) =>
      fetch(
        `${c.SUPABASE_URL}/storage/v1/object/${BUCKET}/${tenantId}/logo.${ext}`,
        {
          method: 'DELETE',
          headers: {
            apikey: c.SUPABASE_ANON_KEY,
            Authorization: `Bearer ${session.access_token}`,
          },
        }
      ).catch(() => {})
    )
  );
}


/* ════════════════════════════════════════════════════════════════════════
   Public API
   ════════════════════════════════════════════════════════════════════════ */

/**
 * Upload a logo file for the current tenant.
 *
 *   const url = await uploadLogo(file);
 *   await setLogoUrl(url);   // ← caller must follow up
 *
 * Throws with .message in:
 *   no_file, no_tenant_context, not_authenticated, file_too_large,
 *   unsupported_mime, upload_failed
 *
 * Cleans up any pre-existing logo.<other_ext> in the same folder so
 * we don't accumulate orphans when the admin re-uploads with a
 * different format (PNG → SVG, etc.).
 *
 * Returns the public URL with a ?v=<timestamp> cache-buster appended,
 * so CDNs / browsers don't serve a stale image after re-upload to
 * the same path.
 */
export async function uploadLogo(file) {
  if (!file)                                throw new Error('no_file');
  if (file.size > MAX_BYTES)                throw new Error('file_too_large');
  const ext = MIME_TO_EXT[file.type];
  if (!ext)                                 throw new Error('unsupported_mime');

  const tenant = await getTenant();
  if (!tenant)                              throw new Error('no_tenant_context');
  const session = await getSessionOrThrow();

  const c = cfg();
  const tenantId = tenant.id;

  // Clean up siblings first so re-uploading png-after-svg doesn't
  // leave a dead .svg in the bucket.
  await deleteAllLogoFiles(tenantId, session);

  const path = `${tenantId}/logo.${ext}`;
  const res = await fetch(`${c.SUPABASE_URL}/storage/v1/object/${BUCKET}/${path}`, {
    method: 'POST',
    headers: {
      apikey: c.SUPABASE_ANON_KEY,
      Authorization: `Bearer ${session.access_token}`,
      'Content-Type': file.type,
      'x-upsert': 'true',
    },
    body: file,
  });

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    const err = new Error('upload_failed');
    err.status = res.status;
    err.body   = body.slice(0, 300);
    throw err;
  }

  return publicUrlFor(c.SUPABASE_URL, path) + `?v=${Date.now()}`;
}

/**
 * Persist the logo URL on the tenants row via the SECURITY DEFINER
 * RPC. Pass null (or omit) to clear the logo.
 *
 * Throws with .message in:
 *   no_tenant_context, not_authenticated, not_tenant_admin,
 *   invalid_url
 */
export async function setLogoUrl(url) {
  const tenant = await getTenant();
  if (!tenant) throw new Error('no_tenant_context');
  const client = createClient({ tenantId: tenant.id });

  const res = await client.raw('/rest/v1/rpc/set_tenant_logo', {
    method: 'POST',
    body: JSON.stringify({ p_url: url ?? null }),
  });

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    let code = `http_${res.status}`;
    try {
      const parsed = JSON.parse(body);
      if (parsed.message) code = parsed.message;
    } catch { /* keep fallback */ }
    const err = new Error(code);
    err.status = res.status;
    err.body   = body;
    throw err;
  }

  // applyTenantTheme on the next render needs fresh tenant data so the
  // logo URL change (or removal) takes effect immediately.
  clearTenantCache();
  return res.json();
}

/**
 * Best-effort end-to-end remove: delete all logo files in Storage,
 * then clear the URL on the tenants row. Storage failures don't
 * block the DB clear (the DB is the source of truth for whether
 * the tenant "has" a logo).
 */
export async function removeLogo() {
  const tenant = await getTenant();
  if (!tenant) throw new Error('no_tenant_context');
  const session = await getSessionOrThrow();

  await deleteAllLogoFiles(tenant.id, session);
  return setLogoUrl(null);
}

export default { uploadLogo, setLogoUrl, removeLogo };
