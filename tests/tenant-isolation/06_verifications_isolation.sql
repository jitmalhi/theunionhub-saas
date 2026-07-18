-- =============================================================================
-- 06_verifications_isolation.sql — verification records isolation (0041 target)
-- =============================================================================
-- verifications_admin_read was one of the boolean-only policies fixed by 0041.
-- Proves an admin of Tenant A sees only A's verification records and cannot
-- reach B's. verifications is append-only (writes via record_verification RPC),
-- so any direct modify is denied outright.
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
    (v_mem_a, v_a, 'Ver Member A', 'active'),
    (v_mem_b, v_b, 'Ver Member B', 'active');
  INSERT INTO public.verifications (tenant_id, member_id, result) VALUES
    (v_a, v_mem_a, 'verified'),
    (v_b, v_mem_b, 'verified');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_a)::text, true);
  PERFORM set_config('request.headers',   json_build_object('x-tenant-id', v_a)::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  -- positive: admin A sees A's verifications
  SELECT count(*) INTO v_count FROM public.verifications WHERE tenant_id = v_a;
  ASSERT v_count >= 1, 'FAIL: admin of A cannot read A''s own verification records (positive control).';

  -- isolation: admin A must NOT see B's verifications
  SELECT count(*) INTO v_count FROM public.verifications WHERE tenant_id = v_b;
  ASSERT v_count = 0,
    'FAIL (cross-tenant READ leak): admin of Tenant A read Tenant B verification records.';

  -- modify B denied (append-only: no update policy → 0 rows)
  UPDATE public.verifications SET result = 'invalid' WHERE tenant_id = v_b;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  ASSERT v_rows = 0, 'FAIL (cross-tenant MODIFY): admin of Tenant A updated a Tenant B verification.';

  -- direct write into B denied (no INSERT policy for authenticated)
  v_ok := true;
  BEGIN
    INSERT INTO public.verifications (tenant_id, member_id, result) VALUES (v_b, v_mem_b, 'verified');
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN v_ok := false;
  END;
  ASSERT v_ok = false, 'FAIL (cross-tenant WRITE): admin of Tenant A inserted a Tenant B verification.';

  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS: verification records are tenant-isolated (A reads only A; no cross-tenant write).';
END $$;

ROLLBACK;
