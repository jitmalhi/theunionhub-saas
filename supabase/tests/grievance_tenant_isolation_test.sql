-- =============================================================================
-- grievance_tenant_isolation_test.sql
-- Proves D5: the x-tenant-id header only SELECTS a tenant; the database
-- AUTHORIZES it. A user who belongs to tenant A but sends tenant B's header
-- must be denied — is_request_tenant_member() returns FALSE, which is what
-- makes the ai-service return 403 and RLS return zero rows.
--
-- Run against a DB with migrations 0001–0023 applied (e.g. `supabase db reset`
-- then psql -f, or paste into the SQL editor). Self-contained; rolls back.
-- =============================================================================
BEGIN;

-- Simulate the PostgREST request context (auth.uid + headers) helpers.
CREATE OR REPLACE FUNCTION pg_temp.as_request(p_user uuid, p_tenant uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-tenant-id', p_tenant)::text, true);
END $$;

DO $$
DECLARE
  v_tenant_a uuid;
  v_tenant_b uuid;
  v_user     uuid := gen_random_uuid();
  v_member   uuid := gen_random_uuid();
  v_ok       boolean;
BEGIN
  -- two tenants (contact_email is NOT NULL + format-checked since 0001;
  -- local_number is nullable but set here to match the member_verify test)
  INSERT INTO public.tenants (slug, display_name, local_number, contact_email)
    VALUES ('iso-test-a-' || substr(v_user::text,1,8), 'Iso Test A', '412', 'a@test.local')
    RETURNING id INTO v_tenant_a;
  INSERT INTO public.tenants (slug, display_name, local_number, contact_email)
    VALUES ('iso-test-b-' || substr(v_user::text,1,8), 'Iso Test B', '419', 'b@test.local')
    RETURNING id INTO v_tenant_b;

  -- an auth user, made a STEWARD of tenant A only
  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated',
            'authenticated', 'iso-' || substr(v_user::text,1,8) || '@test.local', now(), now());
  INSERT INTO public.stewards (tenant_id, user_id, full_name)
    VALUES (v_tenant_a, v_user, 'Iso Test Steward');

  -- (1) user + OWN tenant header (A) → allowed
  PERFORM pg_temp.as_request(v_user, v_tenant_a);
  v_ok := public.is_request_tenant_member();
  ASSERT v_ok = true, 'FAIL: member of tenant A was denied their own tenant';

  -- (2) user + OTHER tenant header (B) → DENIED (the D5 case)
  PERFORM pg_temp.as_request(v_user, v_tenant_b);
  v_ok := public.is_request_tenant_member();
  ASSERT v_ok = false, 'FAIL: tenant-A user was ALLOWED into tenant B via a spoofed header';

  -- (3) role resolution matches: A → STEWARD, B → no row
  PERFORM pg_temp.as_request(v_user, v_tenant_a);
  ASSERT (SELECT role FROM public.get_user_role()) = 'STEWARD',
    'FAIL: role for own tenant should be STEWARD';
  PERFORM pg_temp.as_request(v_user, v_tenant_b);
  ASSERT NOT EXISTS (SELECT 1 FROM public.get_user_role()),
    'FAIL: get_user_role() should return no row for a tenant the user is not in';

  RAISE NOTICE 'PASS: header selects the tenant, the database authorizes it. Cross-tenant header denied.';
END $$;

ROLLBACK;
