-- =============================================================================
-- 03_grievance_isolation.sql — grievance/case confidentiality across tenants
-- =============================================================================
-- Grievances are the most legally sensitive data in the platform. Proves an
-- authenticated admin of Tenant A cannot read, insert into, or otherwise reach
-- Tenant B's grievance_cases (and, by cascade, its history/assignments).
--
-- Expected: PASS. Unlike the 0008 members policies, grievance_cases (0024)
-- correctly scopes its SELECT/INSERT with `tenant_id = get_request_tenant_id()`.
-- This test locks that in so a future edit can't regress it.
--
-- Prereq: migrations 0001-0040 + 00_fixtures.sql. Self-contained; rolls back.
-- =============================================================================
BEGIN;

DO $$
DECLARE
  v_a uuid; v_b uuid; v_admin_a uuid; v_admin_b uuid;
  v_mem_b   uuid := gen_random_uuid();
  v_case_b  uuid;
  v_count   integer;
  v_ok      boolean;
BEGIN
  SELECT tenant_a, tenant_b, admin_a, admin_b
    INTO v_a, v_b, v_admin_a, v_admin_b
    FROM iso_test.make_pair();

  -- Tenant B has a member and a confidential grievance case (created as superuser).
  INSERT INTO public.members (id, tenant_id, full_name, status)
    VALUES (v_mem_b, v_b, 'Grievant B', 'active');
  INSERT INTO public.grievance_cases (tenant_id, member_id, case_number, description)
    VALUES (v_b, v_mem_b, 'GRV-ISO-B-1', 'Confidential B matter')
    RETURNING id INTO v_case_b;

  -- Sanity (superuser, RLS bypassed): the B case really exists.
  SELECT count(*) INTO v_count FROM public.grievance_cases WHERE id = v_case_b;
  ASSERT v_count = 1, 'FAIL: fixture grievance for Tenant B was not created (setup error).';

  -- ─── Context: authenticated admin of A, header = A ─────────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_a)::text, true);
  PERFORM set_config('request.headers',   json_build_object('x-tenant-id', v_a)::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  -- CRITICAL: A cannot read B's grievance cases.
  SELECT count(*) INTO v_count FROM public.grievance_cases WHERE tenant_id = v_b;
  ASSERT v_count = 0,
    'FAIL (cross-tenant GRIEVANCE READ leak): admin of Tenant A read Tenant B grievance_cases.';

  -- CRITICAL: A cannot read a specific B case by id.
  SELECT count(*) INTO v_count FROM public.grievance_cases WHERE id = v_case_b;
  ASSERT v_count = 0,
    'FAIL (cross-tenant GRIEVANCE READ leak): admin of Tenant A resolved a Tenant B case by id.';

  -- CRITICAL: A cannot INSERT a grievance into Tenant B.
  v_ok := true;
  BEGIN
    INSERT INTO public.grievance_cases (tenant_id, member_id, case_number)
      VALUES (v_b, v_mem_b, 'GRV-ISO-INJECT');
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN
    v_ok := false;  -- correctly blocked
  END;
  ASSERT v_ok = false,
    'FAIL (cross-tenant GRIEVANCE INSERT): admin of Tenant A created a case in Tenant B.';

  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS: grievance_cases are tenant-isolated (A cannot read or write B''s confidential cases).';
END $$;

ROLLBACK;
