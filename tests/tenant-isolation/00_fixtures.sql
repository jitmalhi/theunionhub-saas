-- =============================================================================
-- 00_fixtures.sql — shared tenant fixtures (SETUP; run once before the suite)
-- =============================================================================
-- Creates a helper in the iso_test schema that builds a two-tenant scaffold
-- (Tenant A + Tenant B, each with one admin). Tests call it INSIDE their own
-- BEGIN…ROLLBACK transaction, so the tenants/users/admins it inserts are rolled
-- back per test — only the helper FUNCTION persists (harmless, no business data).
--
-- The runner executes this first (setup) and drops the iso_test schema after
-- (cleanup). Safe on scratch/local/staging DBs; never run the suite on prod.
--
-- Prereq: migrations 0001-0040 applied.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS iso_test;

-- Build two tenants + one admin each. Returns their ids.
-- Called before any SET ROLE (runs as the caller / migration superuser), so it
-- may write auth.users / tenant_admins.
CREATE OR REPLACE FUNCTION iso_test.make_pair(
  OUT tenant_a uuid, OUT tenant_b uuid, OUT admin_a uuid, OUT admin_b uuid
)
LANGUAGE plpgsql
AS $$
DECLARE
  tag text := substr(gen_random_uuid()::text, 1, 8);
BEGIN
  INSERT INTO public.tenants (slug, display_name, local_number, contact_email)
    VALUES ('iso-a-'||tag, 'Iso A', '412', 'a-'||tag||'@test.local') RETURNING id INTO tenant_a;
  INSERT INTO public.tenants (slug, display_name, local_number, contact_email)
    VALUES ('iso-b-'||tag, 'Iso B', '419', 'b-'||tag||'@test.local') RETURNING id INTO tenant_b;

  admin_a := gen_random_uuid();
  admin_b := gen_random_uuid();
  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    VALUES
      (admin_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'aa-'||tag||'@test.local', now(), now()),
      (admin_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ab-'||tag||'@test.local', now(), now());

  INSERT INTO public.tenant_admins (tenant_id, user_id, role)
    VALUES (tenant_a, admin_a, 'admin'), (tenant_b, admin_b, 'admin');
END;
$$;

COMMENT ON FUNCTION iso_test.make_pair() IS
  'Isolation-suite fixture: creates Tenant A + Tenant B and one admin each. '
  'Call inside a BEGIN…ROLLBACK test. Teardown: DROP SCHEMA iso_test CASCADE.';
