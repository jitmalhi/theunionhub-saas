-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0007 — list_tenant_admins() RPC
-- ════════════════════════════════════════════════════════════════════════
-- Powers the /admin/team page. Returns the explicit tenant admin rows
-- with the joined email addresses from auth.users.
--
-- Why an RPC instead of a direct PostgREST embed:
--   PostgREST CAN embed FK-related rows, but auth.users is in the auth
--   schema and Supabase doesn't expose it for direct anon/authenticated
--   SELECT. We don't want to expose all auth.users either (that's an
--   enumeration of every signed-in user across the platform). The RPC
--   pattern returns ONLY the admins of the current tenant, joined with
--   their emails, after checking the caller is themselves an admin.
--   Defence in depth: bootstrap admins (bootstrap fallback active) can
--   still see the empty list and self-promote; non-admin signed-in users
--   get not_tenant_admin.
--
-- Includes the creator email via a second join, LEFT so backfilled rows
-- (whose created_by is NULL from migration 0006) come back as NULL
-- rather than disappearing. The UI renders NULL as "—".
--
-- Prerequisites: 0006 (tenant_admins + is_tenant_admin).
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.list_tenant_admins()
RETURNS TABLE (
  user_id          uuid,
  email            text,
  role             text,
  created_at       timestamptz,
  created_by       uuid,
  created_by_email text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id uuid;
  v_user_id   uuid;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context';
  END IF;

  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  -- Bootstrap-fallback admins are valid callers — is_tenant_admin handles
  -- that. The function returns 0 rows for tenants in bootstrap mode (no
  -- explicit admins yet); the UI is expected to detect that and show
  -- the "make me a permanent admin" affordance.
  IF NOT public.is_tenant_admin(v_tenant_id, v_user_id) THEN
    RAISE EXCEPTION 'not_tenant_admin';
  END IF;

  RETURN QUERY
  SELECT
    ta.user_id,
    u.email,
    ta.role,
    ta.created_at,
    ta.created_by,
    c.email AS created_by_email
  FROM public.tenant_admins ta
  JOIN auth.users u ON u.id = ta.user_id
  LEFT JOIN auth.users c ON c.id = ta.created_by
  WHERE ta.tenant_id = v_tenant_id
  ORDER BY ta.created_at ASC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.list_tenant_admins() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.list_tenant_admins() TO authenticated;

COMMENT ON FUNCTION public.list_tenant_admins() IS
  'List explicit tenant admins (joined to auth.users) for the current tenant. '
  'Caller must be an admin (bootstrap-fallback admins included). Returns '
  '(user_id, email, role, created_at, created_by, created_by_email). '
  'Returns zero rows for tenants in bootstrap mode — the UI should '
  'detect that and offer to bootstrap.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- As an authenticated admin:
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/list_tenant_admins" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Authorization: Bearer $ACCESS_TOKEN" \
--        -H "Content-Type: application/json" -d '{}'
--   -- Expect: array of {user_id, email, role, created_at, created_by, created_by_email}
--
--   -- As authenticated non-admin:
--   -- Expect: 4xx with code not_tenant_admin
--
--   -- As anon (no Authorization header):
--   -- Expect: 4xx with code not_authenticated
-- ════════════════════════════════════════════════════════════════════════
