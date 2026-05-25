-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0005 — update_tenant_settings() RPC
-- ════════════════════════════════════════════════════════════════════════
-- Unblocks the admin settings page. RLS on public.tenants is read-only
-- by design (anyone visiting demo.theunionhub.com can SELECT to render
-- the card; nobody can mutate). The provisioning script writes via
-- service_role. The admin UI needs a third path: an authenticated user
-- who is the tenant's contact_email should be able to update the
-- non-sensitive display fields without holding the service key.
--
-- The RPC checks the calling user's email against tenants.contact_email
-- BEFORE the UPDATE. SECURITY DEFINER, so the function bypasses the
-- read-only RLS posture, but only after authorisation is proven inside
-- the function body. Then it stamps an audit_log row noting what
-- changed and who changed it.
--
-- What this RPC CANNOT change (deliberately):
--   · slug          — the routing primitive; changing it would break
--                     every existing magic-link and bookmark
--   · contact_email — changing it would let the current admin lock
--                     themselves out and hand control to another email
--   · status        — lifecycle changes (active → archived) belong in
--                     a separate admin tool with a confirmation step
--   · accent contrast — the format is checked by the table CHECK
--                       constraint; WCAG AA is enforced client-side
--                       in settings.html
--
-- Prerequisites:
--   · 0001 (tenants), 0002 (get_request_tenant_id), 0004 (audit_log).
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.update_tenant_settings(
  p_display_name text DEFAULT NULL,
  p_accent_hex   text DEFAULT NULL,
  p_local_number text DEFAULT NULL,
  p_union_type   text DEFAULT NULL
)
RETURNS public.tenants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id    uuid;
  v_user_id      uuid;
  v_user_email   text;
  v_tenant_email text;
  v_result       public.tenants%ROWTYPE;
  v_changed      jsonb;
BEGIN
  -- 1 · Tenant context. Without x-tenant-id we have no idea which
  --     tenant to update; reject loudly so the UI can surface it.
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context'
      USING HINT = 'x-tenant-id header is missing or malformed';
  END IF;

  -- 2 · Caller identity. auth.uid() is Supabase-provided and returns
  --     NULL when the request is anon or service_role.
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated'
      USING HINT = 'Settings updates require a signed-in user';
  END IF;

  -- 3 · Resolve the user's email by joining to auth.users. Done inside
  --     SECURITY DEFINER so we don't grant anon any direct read on
  --     auth.users.
  SELECT email INTO v_user_email
    FROM auth.users
   WHERE id = v_user_id;

  SELECT contact_email INTO v_tenant_email
    FROM public.tenants
   WHERE id = v_tenant_id;

  -- 4 · Email match check. Lower-cased compare because email is
  --     case-insensitive in practice (RFC 5321 §2.4 says the local
  --     part is technically case-sensitive but it's universally
  --     treated as not). Until the multi-admin tenant_admins table
  --     exists, this single-admin model is the gate.
  IF v_tenant_email IS NULL
     OR v_user_email IS NULL
     OR lower(v_user_email) <> lower(v_tenant_email) THEN
    RAISE EXCEPTION 'not_tenant_admin'
      USING HINT = 'Your email does not match the tenant''s contact_email';
  END IF;

  -- 5 · Perform the update. NULLIF('', '') coerces empty-string inputs
  --     to NULL so COALESCE preserves the existing value instead of
  --     blanking the field; pass NULL or omit a param to leave it
  --     untouched.
  UPDATE public.tenants
     SET display_name = COALESCE(NULLIF(trim(p_display_name), ''), display_name),
         accent_hex   = COALESCE(NULLIF(trim(p_accent_hex),   ''), accent_hex),
         local_number = COALESCE(NULLIF(trim(p_local_number), ''), local_number),
         union_type   = COALESCE(NULLIF(trim(p_union_type),   ''), union_type),
         updated_at   = NOW()
   WHERE id = v_tenant_id
   RETURNING * INTO v_result;

  -- 6 · Audit. jsonb_strip_nulls drops fields the caller didn't change
  --     so the detail shows only what was actually modified.
  v_changed := jsonb_strip_nulls(jsonb_build_object(
    'display_name', p_display_name,
    'accent_hex',   p_accent_hex,
    'local_number', p_local_number,
    'union_type',   p_union_type
  ));

  INSERT INTO public.audit_log (
    tenant_id, actor, action, target_type, target_id, detail
  )
  VALUES (
    v_tenant_id,
    'user:' || v_user_id::text,
    'tenant_settings_updated',
    'tenant',
    v_tenant_id,
    jsonb_build_object('actor_email', v_user_email, 'changed', v_changed)
  );

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.update_tenant_settings(text, text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.update_tenant_settings(text, text, text, text) TO authenticated;

COMMENT ON FUNCTION public.update_tenant_settings(text, text, text, text) IS
  'Admin-only mutation of the tenant''s non-sensitive display fields. '
  'SECURITY DEFINER. Requires authenticated user whose email matches the '
  'tenant''s contact_email. Stamps an audit_log row on every successful '
  'update. Raises no_tenant_context / not_authenticated / not_tenant_admin '
  'on the three failure modes.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Function exists with expected signature:
--   \df+ public.update_tenant_settings
--
--   -- Unauthenticated call rejected:
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/update_tenant_settings" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Content-Type: application/json" \
--        -d '{"p_display_name":"hack"}'
--   -- Expect: 4xx with code not_authenticated
--
--   -- Authenticated call from non-admin email rejected:
--   -- (Sign in as some@randomemail.com; get the access_token; then …)
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/update_tenant_settings" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Authorization: Bearer $ACCESS_TOKEN" \
--        -H "Content-Type: application/json" \
--        -d '{"p_display_name":"hack"}'
--   -- Expect: 4xx with code not_tenant_admin
--
-- Known follow-ups:
--   · tenant_admins (tenant_id, user_id, role) table for multi-admin
--     tenants. The single-admin email-match model gets us moving but
--     doesn't survive the first locale that needs a steward team.
--   · Logo upload + UPDATE for tenants.logo_url, which requires
--     Supabase Storage bucket policies (separate migration + RPC).
--   · Allowing contact_email rotation under a "confirm with old + new
--     email" double-opt-in pattern.
-- ════════════════════════════════════════════════════════════════════════
