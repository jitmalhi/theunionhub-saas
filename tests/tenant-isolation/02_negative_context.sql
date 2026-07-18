-- =============================================================================
-- 02_negative_context.sql — missing/invalid tenant context + cross-tenant writes
-- =============================================================================
-- Negative tests: things that MUST fail. Proves the platform denies access when
-- tenant context is absent/wrong, and blocks cross-tenant INSERT/UPDATE/DELETE.
--
-- Expected results against 0008:
--   · missing header      → lookup_member returns 0 (get_request_tenant_id NULL). PASS.
--   · invalid header      → lookup_member returns 0 (no such tenant).            PASS.
--   · cross-tenant INSERT → blocked by members_admin_insert WITH CHECK.          PASS.
--   · cross-tenant UPDATE (reassign B's member into A) → blocked by 0041's row
--       filter on members_admin_update USING (FAILS on the 0001-0040 baseline).
--   · cross-tenant DELETE → blocked by 0041 (FAILS on the 0001-0040 baseline).
--
-- Prereq: migrations 0001–0040. Self-contained; rolls back.
-- =============================================================================
BEGIN;

DO $$
DECLARE
  v_a       uuid;
  v_b       uuid;
  v_admin_a uuid := gen_random_uuid();
  v_mem_b   uuid := gen_random_uuid();
  v_count   integer;
  v_rows    integer;
  v_ok      boolean;
BEGIN
  -- ─── Setup ─────────────────────────────────────────────────────────────
  INSERT INTO public.tenants (slug, display_name, local_number, contact_email)
    VALUES ('iso-neg-a-'||substr(v_admin_a::text,1,8),'Iso Neg A','412','na-'||substr(v_admin_a::text,1,8)||'@test.local')
    RETURNING id INTO v_a;
  INSERT INTO public.tenants (slug, display_name, local_number, contact_email)
    VALUES ('iso-neg-b-'||substr(v_admin_a::text,1,8),'Iso Neg B','419','nb-'||substr(v_admin_a::text,1,8)||'@test.local')
    RETURNING id INTO v_b;
  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    VALUES (v_admin_a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
            'na-'||substr(v_admin_a::text,1,8)||'@test.local', now(), now());
  INSERT INTO public.tenant_admins (tenant_id, user_id, role) VALUES (v_a, v_admin_a, 'admin');
  INSERT INTO public.members (id, tenant_id, full_name, status) VALUES (v_mem_b, v_b, 'Member B', 'active');

  -- ─── (1) MISSING tenant context (anon, no header) ──────────────────────
  PERFORM set_config('request.jwt.claims', NULL, true);
  PERFORM set_config('request.headers', json_build_object()::text, true);  -- no x-tenant-id
  EXECUTE 'SET LOCAL ROLE anon';
  SELECT count(*) INTO v_count FROM public.lookup_member(v_mem_b);
  ASSERT v_count = 0, 'FAIL: lookup_member returned a row with NO tenant context (missing header).';

  -- ─── (2) INVALID tenant header (nonexistent tenant) ────────────────────
  PERFORM set_config('request.headers', json_build_object('x-tenant-id', gen_random_uuid())::text, true);
  SELECT count(*) INTO v_count FROM public.lookup_member(v_mem_b);
  ASSERT v_count = 0, 'FAIL: lookup_member resolved a member under an INVALID/nonexistent tenant header.';

  -- ─── (3) Cross-tenant INSERT (admin A tries to create a member in B) ───
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_a)::text, true);
  PERFORM set_config('request.headers',   json_build_object('x-tenant-id', v_a)::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_ok := true;
  BEGIN
    INSERT INTO public.members (tenant_id, full_name, status) VALUES (v_b, 'Injected B', 'active');
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN
    v_ok := false;  -- correctly blocked by WITH CHECK
  END;
  ASSERT v_ok = false,
    'FAIL (cross-tenant INSERT): admin of Tenant A created a member in Tenant B.';

  -- ─── (4) Cross-tenant UPDATE (admin A tries to STEAL B''s member into A) ─
  UPDATE public.members SET tenant_id = v_a WHERE id = v_mem_b;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  ASSERT v_rows = 0,
    'FAIL (cross-tenant UPDATE/takeover): admin of Tenant A reassigned a Tenant B member into A. '
    'Fix: members_admin_update USING must add `AND tenant_id = public.get_request_tenant_id()`.';

  -- ─── (5) Cross-tenant DELETE ───────────────────────────────────────────
  DELETE FROM public.members WHERE id = v_mem_b;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  ASSERT v_rows = 0,
    'FAIL (cross-tenant DELETE): admin of Tenant A deleted a Tenant B member.';

  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS: missing/invalid context denied; cross-tenant INSERT/UPDATE/DELETE all blocked.';
END $$;

ROLLBACK;
