-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0008 — strict tenant_admins-gated RLS
-- ════════════════════════════════════════════════════════════════════════
-- Closes the last RLS gap. Before this migration, any signed-in user
-- visiting a tenant subdomain could read that tenant's members,
-- verifications, dues_collections, and audit_log — RLS only checked
-- tenant_id matched the x-tenant-id header, not whether the caller was
-- actually an admin of the tenant. Now that 0006 + 0007 give us a real
-- membership table (public.tenant_admins) and is_tenant_admin() helper,
-- we can replace "any signed-in user on this subdomain" with "is this
-- caller an admin of this tenant" everywhere.
--
-- The tricky part — and why this migration is bigger than just dropping
-- and recreating policies — is that the public verify and card pages
-- currently rely on anon SELECT on members. Those pages don't sign in
-- (a verifier scanning a QR is the canonical example). Removing anon
-- SELECT on members without giving anon SOMETHING else to call breaks
-- the entire public surface.
--
-- The fix is a narrow SECURITY DEFINER RPC, lookup_member(p_id), that
-- returns exactly one member by id within the request's tenant context,
-- exposing only the display fields. No way to enumerate the roster
-- (the leak that motivated this migration in the first place), no way
-- to cross tenant boundaries (the RPC reads x-tenant-id itself), and
-- the fields it exposes are the same ones already painted publicly on
-- the verify and card pages.
--
-- Three of the existing RPCs (record_verification, check_already_collected,
-- mark_member_paid from 0004) were SECURITY INVOKER and relied on RLS
-- to filter their internal SELECT on members. After this migration RLS
-- on members denies anon, so those internal SELECTs would always fail
-- under INVOKER. Flipping them to DEFINER and adding an explicit
-- tenant_id check in their WHERE clauses preserves the verify flow.
--
-- After this migration:
--
--   anon
--     · CAN  call lookup_member(id) — one row at a time, in-tenant
--     · CAN  call record_verification(id, result)        (DEFINER)
--     · CAN  call check_already_collected(id)            (DEFINER)
--     · CAN  call mark_member_paid(id)                   (DEFINER)
--     · CANNOT  SELECT public.members            (no policy)
--     · CANNOT  SELECT public.verifications      (no policy)
--     · CANNOT  SELECT public.dues_collections   (no policy)
--     · CANNOT  SELECT public.audit_log          (was never allowed)
--
--   authenticated NOT in tenant_admins for the current tenant
--     · same as anon — no admin tables visible at all
--
--   authenticated IN tenant_admins for the current tenant
--     · CAN  SELECT/INSERT/UPDATE/DELETE public.members
--     · CAN  SELECT public.verifications + dues_collections + audit_log
--     · (writes to verifications/dues still go through the RPCs)
--
--   service_role
--     · bypasses everything (provisioning script, migration ops)
--
-- Prerequisites: 0001 (tenants), 0002 (get_request_tenant_id),
--                0004 (verifications + dues_collections + audit_log),
--                0006 (tenant_admins + is_tenant_admin).
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ─── 1 · is_request_tenant_admin() helper ──────────────────────────────
-- Convenience wrapper around is_tenant_admin() that pulls the tenant id
-- from the request header and the user id from auth.uid(). Used by every
-- RLS policy below so the policies stay readable.
--
-- SECURITY INVOKER because all the privileged work (reading tenant_admins,
-- joining to auth.users for the bootstrap fallback) already happens
-- inside is_tenant_admin, which IS SECURITY DEFINER. Wrapping a DEFINER
-- in an INVOKER doesn't compromise the bypass — the inner function still
-- runs as its owner.
CREATE OR REPLACE FUNCTION public.is_request_tenant_admin()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT public.is_tenant_admin(public.get_request_tenant_id(), auth.uid());
$$;

REVOKE EXECUTE ON FUNCTION public.is_request_tenant_admin() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.is_request_tenant_admin() TO anon, authenticated;

COMMENT ON FUNCTION public.is_request_tenant_admin() IS
  'Convenience wrapper: is_tenant_admin(get_request_tenant_id(), auth.uid()). '
  'Used by RLS policies on members/verifications/dues_collections/audit_log.';


-- ─── 2 · lookup_member(p_id) — anon-callable single-row member fetch ──
-- The only path anon has to read members after this migration. Returns
-- the same shape card.html and verify.html have always painted; nothing
-- new is exposed publicly that wasn't already visible to anyone who
-- scanned a QR.
--
-- No enumeration: takes a single id parameter, returns at most one row,
-- always filtered to the tenant in the x-tenant-id header. An attacker
-- without a valid member uuid gets nothing useful.
--
-- No cross-tenant: the function reads get_request_tenant_id() itself
-- rather than trusting the caller to filter; sending a member id from
-- local419 with x-tenant-id for local183 returns empty.
CREATE OR REPLACE FUNCTION public.lookup_member(p_id uuid)
RETURNS TABLE (
  id            uuid,
  full_name     text,
  union_name    text,
  local_number  text,
  member_since  date,
  status        text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL OR p_id IS NULL THEN
    RETURN;  -- empty result; anon gets []
  END IF;

  RETURN QUERY
  SELECT m.id, m.full_name, m.union_name, m.local_number, m.member_since, m.status
    FROM public.members m
   WHERE m.id = p_id
     AND m.tenant_id = v_tenant_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.lookup_member(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.lookup_member(uuid) TO anon, authenticated;

COMMENT ON FUNCTION public.lookup_member(uuid) IS
  'Single-row member lookup scoped to the current tenant. SECURITY DEFINER '
  'so anon can call it after 0008 removes their direct SELECT on members. '
  'Returns only the display fields card.html and verify.html paint — never '
  'contact info, internal notes, or anything else added to public.members '
  'in future migrations. Add new fields to this RETURNS TABLE explicitly.';


-- ─── 3 · Re-grant verification RPCs as SECURITY DEFINER ────────────────
-- record_verification, check_already_collected, mark_member_paid were
-- SECURITY INVOKER in 0004 and relied on the anon SELECT policy on
-- members to validate their internal lookups. With anon SELECT on
-- members removed below, those internal SELECTs would always return
-- nothing under INVOKER. Flipping to DEFINER bypasses RLS for the
-- internal checks; the explicit tenant_id filter in each WHERE clause
-- preserves tenant scoping (which was previously done implicitly by RLS).

CREATE OR REPLACE FUNCTION public.record_verification(
  p_member_id uuid,
  p_result    text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RETURN;
  END IF;

  -- Explicit tenant_id filter — RLS no longer scopes for us under DEFINER.
  IF NOT EXISTS (
    SELECT 1 FROM public.members
     WHERE id = p_member_id AND tenant_id = v_tenant_id
  ) THEN
    RETURN;
  END IF;

  BEGIN
    INSERT INTO public.verifications (tenant_id, member_id, result)
    VALUES (v_tenant_id, p_member_id, p_result);
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- logging never breaks the verify flow
  END;
END;
$$;


CREATE OR REPLACE FUNCTION public.check_already_collected(p_member_id uuid)
RETURNS TABLE (already boolean, paid_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_collected_at timestamptz;
BEGIN
  -- Already tenant-scoped via the WHERE clause; this function didn't
  -- need an internal members check. Flip to DEFINER just for
  -- consistency with the other two and because dues_collections RLS
  -- below denies direct anon SELECT.
  SELECT collected_at INTO v_collected_at
    FROM public.dues_collections
   WHERE tenant_id       = public.get_request_tenant_id()
     AND member_id       = p_member_id
     AND collection_date = current_date
   LIMIT 1;

  IF v_collected_at IS NOT NULL THEN
    RETURN QUERY SELECT true,  v_collected_at;
  ELSE
    RETURN QUERY SELECT false, NULL::timestamptz;
  END IF;
END;
$$;


CREATE OR REPLACE FUNCTION public.mark_member_paid(p_member_id uuid)
RETURNS TABLE (was_already_paid boolean, paid_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id    uuid;
  v_existing_at  timestamptz;
  v_new_at       timestamptz;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context'
      USING HINT = 'x-tenant-id header is missing or unresolvable';
  END IF;

  -- Explicit tenant_id filter (RLS no longer scopes under DEFINER).
  IF NOT EXISTS (
    SELECT 1 FROM public.members
     WHERE id = p_member_id AND tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'member_not_found_in_tenant'
      USING HINT = 'Member UUID does not exist in this tenant';
  END IF;

  SELECT collected_at INTO v_existing_at
    FROM public.dues_collections
   WHERE tenant_id       = v_tenant_id
     AND member_id       = p_member_id
     AND collection_date = current_date
   LIMIT 1;

  IF v_existing_at IS NOT NULL THEN
    RETURN QUERY SELECT true, v_existing_at;
    RETURN;
  END IF;

  BEGIN
    INSERT INTO public.dues_collections (tenant_id, member_id)
    VALUES (v_tenant_id, p_member_id)
    RETURNING collected_at INTO v_new_at;

    RETURN QUERY SELECT false, v_new_at;
  EXCEPTION WHEN unique_violation THEN
    SELECT collected_at INTO v_existing_at
      FROM public.dues_collections
     WHERE tenant_id       = v_tenant_id
       AND member_id       = p_member_id
       AND collection_date = current_date
     LIMIT 1;
    RETURN QUERY SELECT true, v_existing_at;
  END;
END;
$$;

-- Existing grants from 0004 are preserved by CREATE OR REPLACE; no
-- re-grant needed. The functions are still callable by anon + authenticated.


-- ─── 4 · members RLS — tighten ─────────────────────────────────────────
-- Drop everything from 0002 and rebuild. anon gets no policies (must use
-- lookup_member RPC instead). authenticated gets four CRUD policies all
-- gated on is_request_tenant_admin(). FORCE RLS stays on from 0002.

DROP POLICY IF EXISTS members_tenant_isolated_read   ON public.members;
DROP POLICY IF EXISTS members_tenant_isolated_insert ON public.members;
DROP POLICY IF EXISTS members_tenant_isolated_update ON public.members;
DROP POLICY IF EXISTS members_tenant_isolated_delete ON public.members;

CREATE POLICY members_admin_read
  ON public.members
  FOR SELECT
  TO authenticated
  USING (public.is_request_tenant_admin());

CREATE POLICY members_admin_insert
  ON public.members
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_request_tenant_admin()
    AND tenant_id = public.get_request_tenant_id()
  );

CREATE POLICY members_admin_update
  ON public.members
  FOR UPDATE
  TO authenticated
  USING (public.is_request_tenant_admin())
  WITH CHECK (
    public.is_request_tenant_admin()
    AND tenant_id = public.get_request_tenant_id()
  );

CREATE POLICY members_admin_delete
  ON public.members
  FOR DELETE
  TO authenticated
  USING (public.is_request_tenant_admin());


-- ─── 5 · verifications RLS — tighten ───────────────────────────────────
-- The anon INSERT policy from 0004 was dead code (verify.html always
-- called record_verification RPC, never direct INSERT). Drop it.
-- Direct authenticated SELECT now requires admin membership.

DROP POLICY IF EXISTS verifications_tenant_isolated_read   ON public.verifications;
DROP POLICY IF EXISTS verifications_tenant_isolated_insert ON public.verifications;

CREATE POLICY verifications_admin_read
  ON public.verifications
  FOR SELECT
  TO authenticated
  USING (public.is_request_tenant_admin());

-- No INSERT policy. Writes only via record_verification RPC (DEFINER).
-- No UPDATE/DELETE policies. Append-only invariant from 0004 holds.


-- ─── 6 · dues_collections RLS — tighten ────────────────────────────────
DROP POLICY IF EXISTS dues_tenant_isolated_read   ON public.dues_collections;
DROP POLICY IF EXISTS dues_tenant_isolated_insert ON public.dues_collections;

CREATE POLICY dues_admin_read
  ON public.dues_collections
  FOR SELECT
  TO authenticated
  USING (public.is_request_tenant_admin());

-- No INSERT policy. Writes only via mark_member_paid RPC (DEFINER).


-- ─── 7 · audit_log RLS — tighten ───────────────────────────────────────
DROP POLICY IF EXISTS audit_log_authenticated_read ON public.audit_log;

CREATE POLICY audit_log_admin_read
  ON public.audit_log
  FOR SELECT
  TO authenticated
  USING (public.is_request_tenant_admin());


-- ─── 8 · Comments ──────────────────────────────────────────────────────
COMMENT ON POLICY members_admin_read       ON public.members           IS 'Tightened in 0008: requires tenant_admins membership (or bootstrap). anon must use lookup_member RPC.';
COMMENT ON POLICY verifications_admin_read ON public.verifications     IS 'Tightened in 0008: requires tenant_admins membership.';
COMMENT ON POLICY dues_admin_read          ON public.dues_collections  IS 'Tightened in 0008: requires tenant_admins membership.';
COMMENT ON POLICY audit_log_admin_read     ON public.audit_log         IS 'Tightened in 0008: requires tenant_admins membership.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Anon enumeration of members should now return empty even WITH the
--   -- right tenant header. This is the leak this migration closes:
--   curl -s "$SUPABASE_URL/rest/v1/members?select=id" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID"
--   -- Expect: []
--
--   -- Anon single-row lookup via the new RPC should work:
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/lookup_member" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Content-Type: application/json" \
--        -d '{"p_id":"550bc413-53db-4f83-98e4-7c5c44d721d0"}'
--   -- Expect: [{"id":"...","full_name":"...","status":"active",...}]
--
--   -- Wrong tenant: empty even with a valid member id:
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/lookup_member" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: 00000000-0000-0000-0000-000000000000" \
--        -H "Content-Type: application/json" \
--        -d '{"p_id":"550bc413-53db-4f83-98e4-7c5c44d721d0"}'
--   -- Expect: []
--
--   -- Authenticated NON-admin should see empty members list (this is the
--   -- gap this migration closes):
--   -- (Sign in as some random email that is NOT in tenant_admins, then…)
--   curl -s "$SUPABASE_URL/rest/v1/members?select=id" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Authorization: Bearer $RANDOM_USER_TOKEN"
--   -- Expect: []
--
--   -- Authenticated admin sees the full list:
--   curl -s "$SUPABASE_URL/rest/v1/members?select=id" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Authorization: Bearer $ADMIN_TOKEN"
--   -- Expect: full list
--
--   -- verify.html flow end-to-end (anon → RPCs):
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/record_verification" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Content-Type: application/json" \
--        -d '{"p_member_id":"550bc413-53db-4f83-98e4-7c5c44d721d0","p_result":"verified"}'
--   -- Expect: 204 (function returns void)
--
-- Known follow-ups (none blocking, all separate slices):
--
--   · A `lookup_recent_verifications(p_member_id)` RPC if any public
--     surface ever needs to display a member's recent verification
--     history without an admin session.
--
--   · Splitting authenticated INSERT/UPDATE/DELETE on members further
--     into role-based grants once tenant_admins has a 'viewer' role.
--
--   · Tightening the lookup_member return shape: today it returns
--     union_name + local_number from public.members (denormalised from
--     tenants). Once those columns are dropped (the follow-up flagged
--     in 0002), the RPC will JOIN public.tenants to derive them.
-- ════════════════════════════════════════════════════════════════════════
