-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0011 — tenant logo upload
-- ════════════════════════════════════════════════════════════════════════
-- Closes the last admin surface: tenants can upload a logo that paints
-- on the member card (replacing the canonical platform mark). Three
-- pieces:
--
--   1. Supabase Storage bucket `tenant-assets` (public read, admin
--      write). Path convention: <tenant_id>/logo.<ext>.
--   2. RLS policies on storage.objects that gate writes by
--      is_tenant_admin against the path's first folder (the tenant id).
--   3. SECURITY DEFINER RPC public.set_tenant_logo(p_url) that updates
--      tenants.logo_url with an audit entry. Removing a logo is a NULL
--      url through the same RPC.
--
-- Why a separate RPC instead of folding logo_url into update_tenant_settings:
--
--   The logo is a distinct UX flow (file upload, preview, in-place
--   replace) with its own audit semantics: 'tenant_logo_updated' vs
--   'tenant_logo_removed' tells the audit reader what actually
--   happened. Stuffing logo_url into update_tenant_settings would
--   bury that signal in a generic 'tenant_settings_updated' row.
--
-- Why the bucket is public:
--
--   Logos render on the member card (which anon visitors hit). A
--   public bucket lets the browser fetch the image with one round
--   trip and no Authorization plumbing. The tenant_id in the path
--   is also not secret (it's already in the x-tenant-* response
--   headers the middleware sets). Read access leaks nothing beyond
--   what the card itself already shows.
--
-- Prerequisites: 0001 (tenants), 0006 (is_tenant_admin), 0008 (the
--                strict-RLS world where authenticated admin writes
--                are gated by tenant membership). The migration
--                assumes the Supabase storage extension is installed
--                (it is in every Supabase project by default).
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ─── 1 · Storage bucket ────────────────────────────────────────────────
-- Idempotent insert. ON CONFLICT DO UPDATE lets us evolve the size
-- limit + allowed types in a future migration by re-running this block.
--
-- Size limit: 5 MiB. SVG is allowed for crisp logos.

INSERT INTO storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
)
VALUES (
  'tenant-assets',
  'tenant-assets',
  true,
  5242880,
  ARRAY['image/png', 'image/jpeg', 'image/svg+xml', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;


-- ─── 2 · Storage RLS policies ──────────────────────────────────────────
-- storage.objects already has RLS enabled by Supabase. We add four
-- policies scoped to bucket_id = 'tenant-assets'.
--
-- Public read: anon + authenticated can SELECT any object in the bucket.
-- Required because the card page renders the logo without auth. The
-- bucket is also marked public above so the /object/public/ URL pattern
-- works without an Authorization header.
--
-- Admin INSERT/UPDATE/DELETE: caller must be a tenant_admin of the
-- tenant whose UUID matches the first folder of the object path. The
-- CASE guard prevents the ::uuid cast from raising when the path
-- doesn't start with a UUID-shaped string — is_tenant_admin treats
-- NULL tenant_id as false, so non-UUID paths are silently denied.

DROP POLICY IF EXISTS tenant_assets_public_read ON storage.objects;
CREATE POLICY tenant_assets_public_read
  ON storage.objects
  FOR SELECT
  TO anon, authenticated
  USING (bucket_id = 'tenant-assets');

DROP POLICY IF EXISTS tenant_assets_admin_insert ON storage.objects;
CREATE POLICY tenant_assets_admin_insert
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'tenant-assets'
    AND public.is_tenant_admin(
      CASE WHEN split_part(name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           THEN split_part(name, '/', 1)::uuid
           ELSE NULL END,
      auth.uid()
    )
  );

DROP POLICY IF EXISTS tenant_assets_admin_update ON storage.objects;
CREATE POLICY tenant_assets_admin_update
  ON storage.objects
  FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'tenant-assets'
    AND public.is_tenant_admin(
      CASE WHEN split_part(name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           THEN split_part(name, '/', 1)::uuid
           ELSE NULL END,
      auth.uid()
    )
  );

DROP POLICY IF EXISTS tenant_assets_admin_delete ON storage.objects;
CREATE POLICY tenant_assets_admin_delete
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'tenant-assets'
    AND public.is_tenant_admin(
      CASE WHEN split_part(name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           THEN split_part(name, '/', 1)::uuid
           ELSE NULL END,
      auth.uid()
    )
  );


-- ─── 3 · set_tenant_logo(p_url) RPC ────────────────────────────────────
-- The DB side of the upload flow. Client:
--   1. Calls Storage REST to upload bytes to <tenant_id>/logo.<ext>.
--   2. Constructs the public URL.
--   3. Calls this RPC with the URL.
-- Removing a logo is the same RPC with p_url = NULL (or empty).
--
-- Validates the URL shape (must be http(s)) as cheap defence — the
-- real authorisation is the is_tenant_admin check. The actual file
-- bytes are NOT validated here; Storage RLS + bucket allowed_mime_types
-- enforce that at upload time.
--
-- Audit action distinguishes set vs remove so the audit log reader
-- doesn't have to inspect the detail JSON to know what happened.

CREATE OR REPLACE FUNCTION public.set_tenant_logo(p_url text DEFAULT NULL)
RETURNS public.tenants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id   uuid;
  v_user_id     uuid;
  v_user_email  text;
  v_old_url     text;
  v_new_url     text;
  v_result      public.tenants%ROWTYPE;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context';
  END IF;

  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.is_tenant_admin(v_tenant_id, v_user_id) THEN
    RAISE EXCEPTION 'not_tenant_admin'
      USING HINT = 'You are not an admin of this tenant';
  END IF;

  v_new_url := NULLIF(trim(p_url), '');

  -- Cheap URL shape check. We don't enforce a specific origin because
  -- a tenant might host their logo elsewhere down the road; the real
  -- guard is admin-only write.
  IF v_new_url IS NOT NULL AND v_new_url !~* '^https?://' THEN
    RAISE EXCEPTION 'invalid_url'
      USING HINT = 'logo_url must start with http:// or https://';
  END IF;

  SELECT logo_url INTO v_old_url FROM public.tenants WHERE id = v_tenant_id;

  UPDATE public.tenants
     SET logo_url   = v_new_url,
         updated_at = NOW()
   WHERE id = v_tenant_id
   RETURNING * INTO v_result;

  SELECT email INTO v_user_email FROM auth.users WHERE id = v_user_id;

  INSERT INTO public.audit_log (
    tenant_id, actor, action, target_type, target_id, detail
  )
  VALUES (
    v_tenant_id,
    'user:' || v_user_id::text,
    CASE WHEN v_new_url IS NULL THEN 'tenant_logo_removed'
                                ELSE 'tenant_logo_updated' END,
    'tenant',
    v_tenant_id,
    jsonb_build_object(
      'actor_email', v_user_email,
      'old_url',     v_old_url,
      'new_url',     v_new_url
    )
  );

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_tenant_logo(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.set_tenant_logo(text) TO authenticated;

COMMENT ON FUNCTION public.set_tenant_logo(text) IS
  'Updates tenants.logo_url. Admin-only via is_tenant_admin. NULL or '
  'empty p_url clears the logo (action ''tenant_logo_removed''); any '
  'http(s) URL sets it (action ''tenant_logo_updated''). Storage file '
  'cleanup is the client''s job.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Bucket exists with the right limits:
--   SELECT id, public, file_size_limit, allowed_mime_types
--     FROM storage.buckets WHERE id = 'tenant-assets';
--
--   -- Four policies on storage.objects scoped to the bucket:
--   SELECT polname FROM pg_policy
--    WHERE polrelid = 'storage.objects'::regclass
--      AND polname LIKE 'tenant_assets_%'
--    ORDER BY polname;
--
--   -- As an authenticated admin: upload a logo via Storage REST.
--   curl -X POST \
--     "$SUPABASE_URL/storage/v1/object/tenant-assets/$DEMO_UUID/logo.png" \
--     -H "apikey: $SUPABASE_ANON_KEY" \
--     -H "Authorization: Bearer $ADMIN_TOKEN" \
--     -H "Content-Type: image/png" \
--     -H "x-upsert: true" \
--     --data-binary @logo.png
--
--   -- Then set the URL on the tenant row:
--   curl -X POST "$SUPABASE_URL/rest/v1/rpc/set_tenant_logo" \
--     -H "apikey: $SUPABASE_ANON_KEY" \
--     -H "x-tenant-id: $DEMO_UUID" \
--     -H "Authorization: Bearer $ADMIN_TOKEN" \
--     -H "Content-Type: application/json" \
--     -d "{\"p_url\":\"$SUPABASE_URL/storage/v1/object/public/tenant-assets/$DEMO_UUID/logo.png\"}"
--
--   -- Non-admin upload attempt is rejected by storage RLS:
--   -- (same POST as above with $RANDOM_USER_TOKEN → 4xx)
--
--   -- Cross-tenant attempt (admin of tenant A uploading to tenant B's
--   -- path): also rejected — is_tenant_admin returns false because
--   -- the path's first folder is tenant B's id.
--
-- Known follow-ups (not blocking):
--   · Image dimension validation server-side (today: client validates
--     mime + size only; bad-aspect logos render poorly but upload OK).
--   · Logo CDN cache invalidation when re-uploading to the same path
--     — handled today by the client appending ?v=<timestamp> to the
--     URL it stores.
--   · Webhook / scheduled cleanup of orphaned Storage objects when a
--     tenant is archived — today they linger.
-- ════════════════════════════════════════════════════════════════════════
