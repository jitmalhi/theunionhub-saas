-- =============================================================================
-- 01_members_isolation.sql — authenticated-admin cross-tenant isolation
-- =============================================================================
-- Proves the strongest members guarantee: an authenticated ADMIN of Tenant A
-- must be able to read/modify ONLY Tenant A's members — never Tenant B's.
--
-- This is deliberately harder than the existing member_verify test (which only
-- checks anon + authenticated NON-admin). It targets the admin read/delete
-- policies from 0008.
--
-- ⚠ EXPECTED TO FAIL against migration 0008 as written. The read/update/delete
--   policies use `USING (public.is_request_tenant_admin())` with NO row-level
--   `tenant_id = public.get_request_tenant_id()` filter. is_request_tenant_admin()
--   is a per-REQUEST boolean, so it is true for EVERY row once the caller is an
--   admin of the header tenant → cross-tenant read/delete. See the FAIL messages
--   and docs/TENANT_ISOLATION_TESTING.md for the fix.
--
-- Prereq: migrations 0001–0040 applied. Self-contained; rolls back.
-- Role handling: SET LOCAL ROLE from the migration superuser; request.headers /
-- request.jwt.claims are transaction-local.
-- =============================================================================
BEGIN;

DO $$
DECLARE
  v_a        uuid;
  v_b        uuid;
  v_admin_a  uuid := gen_random_uuid();
  v_mem_a    uuid := gen_random_uuid();
  v_mem_b    uuid := gen_random_uuid();
  v_count    integer;
  v_rows     integer;
BEGIN
  -- ─── Setup (superuser) ─────────────────────────────────────────────────
  INSERT INTO public.tenants (slug, display_name, local_number, contact_email)
    VALUES ('iso-mem-a-'||substr(v_admin_a::text,1,8),'Iso Mem A','412','a-'||substr(v_admin_a::text,1,8)||'@test.local')
    RETURNING id INTO v_a;
  INSERT INTO public.tenants (slug, display_name, local_number, contact_email)
    VALUES ('iso-mem-b-'||substr(v_admin_a::text,1,8),'Iso Mem B','419','b-'||substr(v_admin_a::text,1,8)||'@test.local')
    RETURNING id INTO v_b;

  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    VALUES (v_admin_a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
            'adm-'||substr(v_admin_a::text,1,8)||'@test.local', now(), now());

  -- v_admin_a is an EXPLICIT admin of tenant A only.
  INSERT INTO public.tenant_admins (tenant_id, user_id, role) VALUES (v_a, v_admin_a, 'admin');

  INSERT INTO public.members (id, tenant_id, full_name, status) VALUES (v_mem_a, v_a, 'Member A', 'active');
  INSERT INTO public.members (id, tenant_id, full_name, status) VALUES (v_mem_b, v_b, 'Member B', 'active');

  -- ─── Context: authenticated admin of A, header = A ─────────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_a)::text, true);
  PERFORM set_config('request.headers',   json_build_object('x-tenant-id', v_a)::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  -- POSITIVE control: admin of A can read A's own members.
  SELECT count(*) INTO v_count FROM public.members WHERE tenant_id = v_a;
  ASSERT v_count >= 1, 'FAIL: admin of Tenant A cannot read its OWN members (positive control broke).';

  -- CRITICAL isolation: admin of A must NOT read Tenant B's members.
  SELECT count(*) INTO v_count FROM public.members WHERE tenant_id = v_b;
  ASSERT v_count = 0,
    'FAIL (cross-tenant READ leak): admin of Tenant A read Tenant B members. '
    'Fix: members_admin_read USING must add `AND tenant_id = public.get_request_tenant_id()`.';

  -- CRITICAL isolation: a specific B member row must be invisible.
  SELECT count(*) INTO v_count FROM public.members WHERE id = v_mem_b;
  ASSERT v_count = 0,
    'FAIL (cross-tenant READ leak): admin of A resolved a specific Tenant B member by id.';

  -- CRITICAL isolation: admin of A must NOT delete Tenant B's member.
  DELETE FROM public.members WHERE id = v_mem_b;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  ASSERT v_rows = 0,
    'FAIL (cross-tenant DELETE): admin of Tenant A deleted a Tenant B member. '
    'Fix: members_admin_delete USING must add `AND tenant_id = public.get_request_tenant_id()`.';

  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS: members are tenant-isolated for authenticated admins (A can read/delete only A).';
END $$;

ROLLBACK;
