-- =============================================================================
-- member_verify_isolation_test.sql
-- Phase 1 (member-id harvest) isolation guarantees for the PUBLIC verification
-- path. Two things must hold:
--
--   (1) DIRECT table reads on public.members are DENIED to the anon (QR scanner)
--       and to authenticated non-admins — after 0008 there is no anon SELECT
--       policy; the only public path is the lookup_member RPC. "Denied" means
--       zero rows (RLS) OR a hard permission error; both are acceptable.
--   (2) A verifier scoped to tenant A CANNOT resolve tenant B's member via
--       lookup_member: the RPC reads get_request_tenant_id() itself and filters
--       server-side, so a member id from B + header A returns nothing.
--
-- Also asserts the positive control: the RIGHT tenant resolves the row and the
-- harvested member_number (0032/0033) comes back on the whitelisted shape.
--
-- Role handling: we SET ROLE from the migration superuser, and RESET ROLE back
-- to it before switching to a different non-superuser role (a non-superuser
-- cannot SET ROLE to another). request.headers / jwt.claims are transaction-
-- local and survive the role changes.
--
-- Run against a DB with migrations 0001–0033 applied (e.g. `supabase db reset`
-- then psql -f, or paste into the SQL editor). Self-contained; rolls back.
-- =============================================================================
BEGIN;

DO $$
DECLARE
  v_tenant_a uuid;
  v_tenant_b uuid;
  v_user     uuid := gen_random_uuid();
  v_member_b uuid := gen_random_uuid();
  v_count    integer;
  v_number   text;
BEGIN
  -- ─── Setup (as the migration superuser, before any SET ROLE) ──────────────
  INSERT INTO public.tenants (slug, display_name, local_number, contact_email)
    VALUES ('iso-mv-a-' || substr(v_user::text,1,8), 'Iso MV A', '412', 'a@test.local')
    RETURNING id INTO v_tenant_a;
  INSERT INTO public.tenants (slug, display_name, local_number, contact_email)
    VALUES ('iso-mv-b-' || substr(v_user::text,1,8), 'Iso MV B', '419', 'b@test.local')
    RETURNING id INTO v_tenant_b;

  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated',
            'authenticated', 'iso-mv-' || substr(v_user::text,1,8) || '@test.local', now(), now());

  -- One member in tenant B, with a member_number (as 0032 would assign).
  INSERT INTO public.members (id, tenant_id, full_name, status, member_number)
    VALUES (v_member_b, v_tenant_b, 'Iso Test Member', 'active', 'M-000001');

  -- ─── ANON scan context (no JWT, just the tenant header) ───────────────────
  PERFORM set_config('request.jwt.claims', NULL, true);
  PERFORM set_config('request.headers', json_build_object('x-tenant-id', v_tenant_b)::text, true);
  EXECUTE 'SET LOCAL ROLE anon';

  -- (1) DIRECT read denied for anon (RLS → 0 rows, or a privilege error).
  BEGIN
    SELECT count(*) INTO v_count FROM public.members;
    ASSERT v_count = 0,
      'FAIL: anon performed a DIRECT read on members (should be 0 — RPC-only path)';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;  -- an outright permission error is an even stronger denial
  END;

  -- (2) Cross-tenant lookup denied: anon scoped to A cannot resolve B's member.
  PERFORM set_config('request.headers', json_build_object('x-tenant-id', v_tenant_a)::text, true);
  SELECT count(*) INTO v_count FROM public.lookup_member(v_member_b);
  ASSERT v_count = 0,
    'FAIL: tenant-A verifier RESOLVED tenant-B member via lookup_member (cross-tenant leak)';

  -- (3) Positive control: the RIGHT tenant resolves + returns member_number.
  PERFORM set_config('request.headers', json_build_object('x-tenant-id', v_tenant_b)::text, true);
  SELECT count(*), max(member_number) INTO v_count, v_number
    FROM public.lookup_member(v_member_b);
  ASSERT v_count = 1,
    'FAIL: tenant-B verifier could not resolve its own member via lookup_member';
  ASSERT v_number = 'M-000001',
    'FAIL: lookup_member did not return the harvested member_number';

  -- ─── AUTHENTICATED non-admin context ──────────────────────────────────────
  EXECUTE 'RESET ROLE';  -- back to superuser before switching roles
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-tenant-id', v_tenant_b)::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  -- DIRECT read denied for authenticated non-admin (members_admin_read needs
  -- is_request_tenant_admin(), which this user is not).
  BEGIN
    SELECT count(*) INTO v_count FROM public.members;
    ASSERT v_count = 0,
      'FAIL: authenticated non-admin performed a DIRECT read on members';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS: members direct-read denied (anon + non-admin); lookup_member is tenant-scoped; member_number exposed on the whitelisted shape only.';
END $$;

ROLLBACK;
