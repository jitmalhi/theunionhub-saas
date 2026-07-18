-- =============================================================================
-- 05_stewards_isolation.sql — stewards cross-tenant delete (finding from audit)
-- =============================================================================
-- The policy audit found stewards_admin_delete (0013) had the same boolean-only
-- USING gap as the members policies: an admin of Tenant A could DELETE Tenant B's
-- stewards. This proves it is closed.
--
-- STATUS: FAILS on the 0001-0040 baseline (proves the gap); PASSES once migration
--   0041 tenant-scopes stewards_admin_delete.
--
-- Prereq: migrations 0001-0041 + 00_fixtures.sql. Self-contained; rolls back.
-- =============================================================================
BEGIN;

DO $$
DECLARE
  v_a uuid; v_b uuid; v_admin_a uuid; v_admin_b uuid;
  v_steward_b uuid := gen_random_uuid();
  v_rows integer;
BEGIN
  SELECT tenant_a, tenant_b, admin_a, admin_b INTO v_a, v_b, v_admin_a, v_admin_b
    FROM iso_test.make_pair();

  INSERT INTO public.stewards (id, tenant_id, full_name)
    VALUES (v_steward_b, v_b, 'Steward B');

  -- Context: authenticated admin of A, header = A.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_a)::text, true);
  PERFORM set_config('request.headers',   json_build_object('x-tenant-id', v_a)::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  DELETE FROM public.stewards WHERE id = v_steward_b;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  ASSERT v_rows = 0,
    'FAIL (cross-tenant DELETE): admin of Tenant A deleted a Tenant B steward. '
    'Fix: 0041 tenant-scopes stewards_admin_delete USING.';

  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS: stewards are tenant-isolated (A cannot delete B stewards).';
END $$;

ROLLBACK;
