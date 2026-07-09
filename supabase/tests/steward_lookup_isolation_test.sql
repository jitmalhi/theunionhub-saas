-- =============================================================================
-- steward_lookup_isolation_test.sql
-- Proves the 0034 fix for the anonymous steward-PII exposure:
--
--   (1) anon has NO direct SELECT on public.stewards (enumeration closed) —
--       zero rows via RLS, or a hard permission error; both count as denied.
--   (2) anon scoped to tenant A cannot resolve tenant B's steward via
--       lookup_steward (no cross-tenant).
--   (3) Positive control: the right tenant resolves the row and gets the
--       public card/vCard fields (name, email) — the RETURNS TABLE shape
--       structurally omits user_id / member_id / created_by / tenant_id.
--
-- Authenticated reads are intentionally NOT tested as denied: stewards_tenant_read
-- still allows any authenticated in-tenant user to read the roster (portal +
-- admin), unchanged from 0013. The exposure this closes is the ANON one.
--
-- Run against a DB with migrations 0001–0034 applied (supabase db reset then
-- psql -f, or the SQL editor). Self-contained; rolls back.
-- =============================================================================
BEGIN;

DO $$
DECLARE
  v_tenant_a  uuid;
  v_tenant_b  uuid;
  v_steward_b uuid := gen_random_uuid();
  v_count     integer;
  v_name      text;
  v_email     text;
BEGIN
  -- ─── Setup (superuser, before any SET ROLE) ───────────────────────────────
  INSERT INTO public.tenants (slug, display_name, local_number, contact_email)
    VALUES ('iso-st-a-' || substr(v_steward_b::text,1,8), 'Iso ST A', '412', 'a@test.local')
    RETURNING id INTO v_tenant_a;
  INSERT INTO public.tenants (slug, display_name, local_number, contact_email)
    VALUES ('iso-st-b-' || substr(v_steward_b::text,1,8), 'Iso ST B', '419', 'b@test.local')
    RETURNING id INTO v_tenant_b;

  INSERT INTO public.stewards (id, tenant_id, full_name, email, phone)
    VALUES (v_steward_b, v_tenant_b, 'Iso Test Steward', 'iso.steward@test.local', '+1-555-0000');

  -- ─── ANON context (no JWT, just the tenant header) ────────────────────────
  PERFORM set_config('request.jwt.claims', NULL, true);
  PERFORM set_config('request.headers', json_build_object('x-tenant-id', v_tenant_b)::text, true);
  EXECUTE 'SET LOCAL ROLE anon';

  -- (1) direct read denied
  BEGIN
    SELECT count(*) INTO v_count FROM public.stewards;
    ASSERT v_count = 0,
      'FAIL: anon performed a DIRECT read on stewards (enumeration should be closed)';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;  -- permission error is an even stronger denial
  END;

  -- (2) cross-tenant lookup denied
  PERFORM set_config('request.headers', json_build_object('x-tenant-id', v_tenant_a)::text, true);
  SELECT count(*) INTO v_count FROM public.lookup_steward(v_steward_b);
  ASSERT v_count = 0,
    'FAIL: tenant-A anon resolved tenant-B steward via lookup_steward (cross-tenant leak)';

  -- (3) positive control: right tenant returns the public fields
  PERFORM set_config('request.headers', json_build_object('x-tenant-id', v_tenant_b)::text, true);
  SELECT count(*), max(full_name), max(email) INTO v_count, v_name, v_email
    FROM public.lookup_steward(v_steward_b);
  ASSERT v_count = 1,
    'FAIL: tenant-B anon could not resolve its own steward via lookup_steward';
  ASSERT v_name = 'Iso Test Steward',
    'FAIL: lookup_steward returned the wrong steward';
  ASSERT v_email = 'iso.steward@test.local',
    'FAIL: lookup_steward did not return the public contact fields';

  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS: stewards direct-read denied to anon; lookup_steward is tenant-scoped and returns only public card fields.';
END $$;

ROLLBACK;
