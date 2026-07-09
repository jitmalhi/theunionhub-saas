-- =============================================================================
-- 0022_grievance_access.sql
-- Access/security core for the merged grievance features.
--
-- Reconciles grievance-system's JWT-tenant + steward_profiles model ONTO the
-- live app's proven pattern: tenant comes from the x-tenant-id header
-- (get_request_tenant_id, 0002) and AUTHORIZATION comes from the database
-- (auth.uid() membership in tenant_admins/stewards). The header SELECTS a
-- tenant; the database DECIDES whether you're allowed in it. The header is
-- never trusted on its own — see is_request_tenant_member() below and the
-- isolation test at supabase/tests/grievance_tenant_isolation_test.sql.
--
-- Depends on: 0001 (tenants), 0002 (members, get_request_tenant_id),
--             0006 (tenant_admins), 0008 (is_request_tenant_admin), 0013 (stewards).
-- Replaces (discarded from grievance-system): current_tenant_id(),
--          steward_profiles, steward_role enum, its get_user_role/current_user_is_*.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- is_request_tenant_member() — THE authorization gate for grievance tables.
-- True iff the authenticated user belongs to the *header* tenant, as either a
-- tenant admin OR a steward. A user from tenant A who spoofs tenant B's header
-- fails this (they have no tenant_admins/stewards row in B) → RLS denies, and
-- the ai-service returns 403. SECURITY DEFINER so it can read the membership
-- tables regardless of the caller's RLS; STABLE so the planner hoists it.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_request_tenant_member()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT public.is_request_tenant_admin()
      OR EXISTS (
        SELECT 1 FROM public.stewards s
        WHERE s.user_id = auth.uid()
          AND s.tenant_id = public.get_request_tenant_id()
      );
$$;

REVOKE ALL ON FUNCTION public.is_request_tenant_member() FROM public;
GRANT EXECUTE ON FUNCTION public.is_request_tenant_member() TO authenticated;

COMMENT ON FUNCTION public.is_request_tenant_member() IS
  'TRUE iff auth.uid() is a tenant_admin or steward of the header tenant. '
  'The database authorization decision behind every grievance-table RLS policy; '
  'the x-tenant-id header alone never grants access.';

-- -----------------------------------------------------------------------------
-- get_user_role() — access role for the current request, derived from live
-- tables (NOT from the discarded steward_profiles). ADMIN if a tenant admin,
-- else STEWARD if a steward of the header tenant, else no row. Returns the
-- header tenant alongside. Consumed by the ai-service Edge Function and the SPA.
-- (STAFF was dropped per decision D2; staff members are modeled as STEWARD.)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_user_role()
RETURNS TABLE (role text, tenant_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT r.role, public.get_request_tenant_id() AS tenant_id
  FROM (
    SELECT CASE
             WHEN public.is_request_tenant_admin() THEN 'ADMIN'
             WHEN EXISTS (
               SELECT 1 FROM public.stewards s
               WHERE s.user_id = auth.uid()
                 AND s.tenant_id = public.get_request_tenant_id()
             ) THEN 'STEWARD'
             ELSE NULL
           END AS role
  ) r
  WHERE r.role IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.get_user_role() FROM public;
GRANT EXECUTE ON FUNCTION public.get_user_role() TO authenticated;

-- -----------------------------------------------------------------------------
-- steward_coverage — which members a steward is responsible for (assignment is
-- an admin action). Reconciled to reference auth.users / live members / tenants
-- (grievance-system referenced steward_profiles, which is discarded).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.steward_coverage (
  user_id    uuid        NOT NULL REFERENCES auth.users(id)     ON DELETE CASCADE,
  member_id  uuid        NOT NULL REFERENCES public.members(id) ON DELETE CASCADE,
  tenant_id  uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE
                           DEFAULT public.get_request_tenant_id(),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, member_id)
);
CREATE INDEX IF NOT EXISTS idx_steward_coverage_member on public.steward_coverage (member_id);
CREATE INDEX IF NOT EXISTS idx_steward_coverage_tenant on public.steward_coverage (tenant_id);

-- Cross-tenant guard: the covered member must belong to the coverage tenant.
CREATE OR REPLACE FUNCTION public.enforce_coverage_tenant_match()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_member_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_member_tenant FROM public.members WHERE id = new.member_id;
  IF v_member_tenant IS NULL THEN
    RAISE EXCEPTION 'no member with id %', new.member_id USING errcode = 'foreign_key_violation';
  END IF;
  IF v_member_tenant <> new.tenant_id THEN
    RAISE EXCEPTION 'cross-tenant coverage blocked: member tenant % <> coverage tenant %',
      v_member_tenant, new.tenant_id USING errcode = 'check_violation';
  END IF;
  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS trg_coverage_tenant_match ON public.steward_coverage;
CREATE TRIGGER trg_coverage_tenant_match
  BEFORE INSERT OR UPDATE ON public.steward_coverage
  FOR EACH ROW EXECUTE FUNCTION public.enforce_coverage_tenant_match();

ALTER TABLE public.steward_coverage ENABLE  ROW LEVEL SECURITY;
ALTER TABLE public.steward_coverage FORCE   ROW LEVEL SECURITY;

-- Read: any member of the header tenant. Write: admins of the header tenant only.
CREATE POLICY steward_coverage_select ON public.steward_coverage
  FOR SELECT TO authenticated
  USING (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_member());

CREATE POLICY steward_coverage_write ON public.steward_coverage
  FOR ALL TO authenticated
  USING      (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_admin())
  WITH CHECK (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_admin());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.steward_coverage TO authenticated;

-- After applying: NOTIFY pgrst, 'reload schema';
