-- =============================================================================
-- 08_dues_isolation.sql — dues / financial records isolation (0041 target)
-- =============================================================================
-- dues_collections EXISTS in the active schema (migrations 0004 + 0010) and
-- dues_admin_read was one of the boolean-only policies fixed by 0041. Financial
-- records are especially sensitive — proves an admin of Tenant A sees only A's
-- dues and cannot read or write B's. Writes go through the mark_member_paid RPC,
-- so there is no direct INSERT policy for authenticated.
--
-- STATUS: read-isolation FAILS on the 0001-0040 baseline (proves the gap);
--   PASSES with 0041 applied. Prereq: 0001-0041 + 00_fixtures.sql. Rolls back.
-- =============================================================================
BEGIN;

DO $$
DECLARE
  v_a uuid; v_b uuid; v_admin_a uuid; v_admin_b uuid;
  v_mem_a uuid := gen_random_uuid();
  v_mem_b uuid := gen_random_uuid();
  v_count integer; v_rows integer; v_ok boolean;
BEGIN
  SELECT tenant_a, tenant_b, admin_a, admin_b INTO v_a, v_b, v_admin_a, v_admin_b
    FROM iso_test.make_pair();

  INSERT INTO public.members (id, tenant_id, full_name, status) VALUES
    (v_mem_a, v_a, 'Dues Member A', 'active'),
    (v_mem_b, v_b, 'Dues Member B', 'active');
  INSERT INTO public.dues_collections (tenant_id, member_id) VALUES
    (v_a, v_mem_a),
    (v_b, v_mem_b);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_a)::text, true);
  PERFORM set_config('request.headers',   json_build_object('x-tenant-id', v_a)::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  -- positive: admin A sees A's dues records
  SELECT count(*) INTO v_count FROM public.dues_collections WHERE tenant_id = v_a;
  ASSERT v_count >= 1, 'FAIL: admin of A cannot read A''s own dues records (positive control).';

  -- isolation: admin A must NOT see B's financial records
  SELECT count(*) INTO v_count FROM public.dues_collections WHERE tenant_id = v_b;
  ASSERT v_count = 0,
    'FAIL (cross-tenant FINANCIAL leak): admin of Tenant A read Tenant B dues records.';

  -- modify B denied (no update policy → 0 rows)
  UPDATE public.dues_collections SET notes = 'tampered' WHERE tenant_id = v_b;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  ASSERT v_rows = 0, 'FAIL (cross-tenant MODIFY): admin of Tenant A modified a Tenant B dues record.';

  -- direct write into B denied (no INSERT policy for authenticated)
  v_ok := true;
  BEGIN
    INSERT INTO public.dues_collections (tenant_id, member_id) VALUES (v_b, v_mem_b);
  EXCEPTION WHEN insufficient_privilege OR check_violation OR unique_violation THEN v_ok := false;
  END;
  ASSERT v_ok = false, 'FAIL (cross-tenant WRITE): admin of Tenant A inserted a Tenant B dues record.';

  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS: dues/financial records are tenant-isolated (A reads only A; no cross-tenant write).';
END $$;

ROLLBACK;
