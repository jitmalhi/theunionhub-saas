-- =============================================================================
-- 07_audit_log_isolation.sql — audit history isolation (0041 target)
-- =============================================================================
-- audit_log_admin_read was one of the boolean-only policies fixed by 0041.
-- Proves an admin of Tenant A views only A's audit history and cannot read B's.
-- audit_log is written only by SECURITY DEFINER functions / service_role — there
-- is no INSERT policy for authenticated, so app users cannot forge audit rows in
-- any tenant context.
--
-- STATUS: read-isolation FAILS on the 0001-0040 baseline (proves the gap);
--   PASSES with 0041 applied. Prereq: 0001-0041 + 00_fixtures.sql. Rolls back.
-- =============================================================================
BEGIN;

DO $$
DECLARE
  v_a uuid; v_b uuid; v_admin_a uuid; v_admin_b uuid;
  v_count integer; v_ok boolean;
BEGIN
  SELECT tenant_a, tenant_b, admin_a, admin_b INTO v_a, v_b, v_admin_a, v_admin_b
    FROM iso_test.make_pair();

  INSERT INTO public.audit_log (tenant_id, actor, action) VALUES
    (v_a, 'system:test', 'iso_event_a'),
    (v_b, 'system:test', 'iso_event_b');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_a)::text, true);
  PERFORM set_config('request.headers',   json_build_object('x-tenant-id', v_a)::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  -- positive: admin A views A's audit history
  SELECT count(*) INTO v_count FROM public.audit_log WHERE tenant_id = v_a;
  ASSERT v_count >= 1, 'FAIL: admin of A cannot read A''s own audit history (positive control).';

  -- isolation: admin A must NOT view B's audit events
  SELECT count(*) INTO v_count FROM public.audit_log WHERE tenant_id = v_b;
  ASSERT v_count = 0,
    'FAIL (cross-tenant READ leak): admin of Tenant A read Tenant B audit events.';

  -- audit rows cannot be inserted with another tenant context (no authenticated INSERT policy)
  v_ok := true;
  BEGIN
    INSERT INTO public.audit_log (tenant_id, actor, action) VALUES (v_b, 'user:forged', 'forged_event');
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN v_ok := false;
  END;
  ASSERT v_ok = false,
    'FAIL (audit forgery): admin of Tenant A inserted an audit record (into Tenant B context).';

  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS: audit history is tenant-isolated (A reads only A; no direct audit inserts).';
END $$;

ROLLBACK;
