-- ============================================================================
-- TENANT ISOLATION GATE — paste-ready bundle for the Supabase SQL Editor
-- ============================================================================
-- Use this when psql is unavailable. Run in the Dashboard → SQL Editor.
--
-- ⚠ HARD RULE: run against a SCRATCH or STAGING project. NEVER production
--   (project ref frdvhmzbsmczknqtexvx). Tests roll themselves back, but the
--   fixtures helper is created in an iso_test schema — do not risk prod.
--
-- ⚠ PREREQUISITE: the target database must have migrations 0001–0040 applied.
--   (The live project is at 0021; 0022–0040 are staged. Push them to the
--   scratch/staging project first — see docs/APPLY-RUNBOOK.md.)
--
-- HOW TO RUN — one block at a time, top to bottom:
--   1. Run STEP 0 (fixtures) once.
--   2. Run each TEST block separately. Note the result of each:
--        • a NOTICE starting "PASS:"  → that test passed
--        • an ERROR mentioning FAIL:/ASSERT → that test failed (record the text)
--      Run them SEPARATELY: a failing test aborts the batch, and on the
--      0040 baseline several are EXPECTED to fail — that is the proof.
--   3. Run STEP 99 (cleanup) at the end.
--
-- EXPECTED RESULT ON THE 0040 BASELINE (before 0041):
--   FAIL on members / verifications / audit_log / dues  ← proves the gap
-- EXPECTED AFTER APPLYING 0041:
--   ALL PASS  ← gate closed
--
-- Send the collected output back and it will be recorded in
-- docs/TENANT_SECURITY_VALIDATION.md.
-- ============================================================================


-- ============================================================================
-- STEP 0 — FIXTURES  (run once, first)
-- ============================================================================
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


-- ============================================================================
-- TEST 1 — 01_members_isolation.sql   ⟵ RUN THIS BLOCK ON ITS OWN
-- ============================================================================
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
-- STATUS: FAILS on the 0001-0040 baseline (proves the gap); PASSES with 0041
--   applied. Root cause: 0008 used `USING (public.is_request_tenant_admin())`
--   with no `tenant_id = public.get_request_tenant_id()` row filter — a
--   per-REQUEST boolean, true for every row. Migration 0041 adds the row filter.
--   See docs/TENANT_ISOLATION_TESTING.md §Remediation history.
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


-- ============================================================================
-- TEST 2 — 02_negative_context.sql   ⟵ RUN THIS BLOCK ON ITS OWN
-- ============================================================================
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


-- ============================================================================
-- TEST 3 — 03_grievance_isolation.sql   ⟵ RUN THIS BLOCK ON ITS OWN
-- ============================================================================
-- =============================================================================
-- 03_grievance_isolation.sql — grievance/case confidentiality across tenants
-- =============================================================================
-- Grievances are the most legally sensitive data in the platform. Proves an
-- authenticated admin of Tenant A cannot read, insert into, or otherwise reach
-- Tenant B's grievance_cases (and, by cascade, its history/assignments).
--
-- Expected: PASS. Unlike the 0008 members policies, grievance_cases (0024)
-- correctly scopes its SELECT/INSERT with `tenant_id = get_request_tenant_id()`.
-- This test locks that in so a future edit can't regress it.
--
-- Prereq: migrations 0001-0040 + 00_fixtures.sql. Self-contained; rolls back.
-- =============================================================================
BEGIN;

DO $$
DECLARE
  v_a uuid; v_b uuid; v_admin_a uuid; v_admin_b uuid;
  v_mem_b   uuid := gen_random_uuid();
  v_case_b  uuid;
  v_count   integer;
  v_ok      boolean;
BEGIN
  SELECT tenant_a, tenant_b, admin_a, admin_b
    INTO v_a, v_b, v_admin_a, v_admin_b
    FROM iso_test.make_pair();

  -- Tenant B has a member and a confidential grievance case (created as superuser).
  INSERT INTO public.members (id, tenant_id, full_name, status)
    VALUES (v_mem_b, v_b, 'Grievant B', 'active');
  INSERT INTO public.grievance_cases (tenant_id, member_id, case_number, description)
    VALUES (v_b, v_mem_b, 'GRV-ISO-B-1', 'Confidential B matter')
    RETURNING id INTO v_case_b;

  -- Sanity (superuser, RLS bypassed): the B case really exists.
  SELECT count(*) INTO v_count FROM public.grievance_cases WHERE id = v_case_b;
  ASSERT v_count = 1, 'FAIL: fixture grievance for Tenant B was not created (setup error).';

  -- ─── Context: authenticated admin of A, header = A ─────────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_a)::text, true);
  PERFORM set_config('request.headers',   json_build_object('x-tenant-id', v_a)::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  -- CRITICAL: A cannot read B's grievance cases.
  SELECT count(*) INTO v_count FROM public.grievance_cases WHERE tenant_id = v_b;
  ASSERT v_count = 0,
    'FAIL (cross-tenant GRIEVANCE READ leak): admin of Tenant A read Tenant B grievance_cases.';

  -- CRITICAL: A cannot read a specific B case by id.
  SELECT count(*) INTO v_count FROM public.grievance_cases WHERE id = v_case_b;
  ASSERT v_count = 0,
    'FAIL (cross-tenant GRIEVANCE READ leak): admin of Tenant A resolved a Tenant B case by id.';

  -- CRITICAL: A cannot INSERT a grievance into Tenant B.
  v_ok := true;
  BEGIN
    INSERT INTO public.grievance_cases (tenant_id, member_id, case_number)
      VALUES (v_b, v_mem_b, 'GRV-ISO-INJECT');
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN
    v_ok := false;  -- correctly blocked
  END;
  ASSERT v_ok = false,
    'FAIL (cross-tenant GRIEVANCE INSERT): admin of Tenant A created a case in Tenant B.';

  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS: grievance_cases are tenant-isolated (A cannot read or write B''s confidential cases).';
END $$;

ROLLBACK;


-- ============================================================================
-- TEST 4 — 04_rpc_inventory.sql   ⟵ RUN THIS BLOCK ON ITS OWN
-- ============================================================================
-- =============================================================================
-- 04_rpc_inventory.sql — SECURITY DEFINER RPC hardening + tenant enforcement
-- =============================================================================
-- Two guarantees for the SECURITY DEFINER surface (functions that run as their
-- owner and therefore BYPASS RLS internally — the highest-risk surface):
--
--   (A) Catalog sweep: EVERY SECURITY DEFINER function in `public` must pin its
--       search_path (SET search_path=...). A DEFINER function without a pinned
--       search_path is a privilege-escalation vector (search_path hijacking).
--       This covers ALL current and FUTURE DEFINER functions automatically.
--
--   (B) Tenant enforcement: the anon-callable member lookup (lookup_member) must
--       read tenant context itself and refuse to resolve another tenant's member.
--
-- The full DEFINER inventory + each function's tenant-enforcement mechanism is
-- documented in docs/TENANT_ISOLATION_TESTING.md §RPC inventory.
--
-- Prereq: migrations 0001-0040 + 00_fixtures.sql. Self-contained; rolls back.
-- =============================================================================
BEGIN;

DO $$
DECLARE
  v_bad     text;
  v_a uuid; v_b uuid; v_admin_a uuid; v_admin_b uuid;
  v_mem_b   uuid := gen_random_uuid();
  v_count   integer;
BEGIN
  -- ─── (A) Every SECURITY DEFINER function in public pins search_path ─────
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_bad
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.prosecdef                                   -- SECURITY DEFINER
     AND NOT EXISTS (
       SELECT 1 FROM unnest(coalesce(p.proconfig, '{}')) c
        WHERE c LIKE 'search_path=%'
     );
  ASSERT v_bad IS NULL,
    'FAIL (DEFINER hardening): these SECURITY DEFINER functions do not pin search_path: ' || v_bad;

  -- ─── (B) lookup_member is tenant-scoped (cross-tenant returns nothing) ──
  SELECT tenant_a, tenant_b, admin_a, admin_b INTO v_a, v_b, v_admin_a, v_admin_b
    FROM iso_test.make_pair();
  INSERT INTO public.members (id, tenant_id, full_name, status)
    VALUES (v_mem_b, v_b, 'RPC Member B', 'active');

  -- anon scoped to A, asking for B's member id → empty.
  PERFORM set_config('request.jwt.claims', NULL, true);
  PERFORM set_config('request.headers', json_build_object('x-tenant-id', v_a)::text, true);
  EXECUTE 'SET LOCAL ROLE anon';
  SELECT count(*) INTO v_count FROM public.lookup_member(v_mem_b);
  ASSERT v_count = 0,
    'FAIL (cross-tenant RPC leak): lookup_member resolved a Tenant B member under Tenant A context.';

  -- positive control: the right tenant resolves it.
  PERFORM set_config('request.headers', json_build_object('x-tenant-id', v_b)::text, true);
  SELECT count(*) INTO v_count FROM public.lookup_member(v_mem_b);
  ASSERT v_count = 1,
    'FAIL: lookup_member could not resolve its OWN tenant''s member (positive control).';

  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS: all SECURITY DEFINER functions pin search_path; lookup_member is tenant-scoped.';
END $$;

ROLLBACK;


-- ============================================================================
-- TEST 5 — 05_stewards_isolation.sql   ⟵ RUN THIS BLOCK ON ITS OWN
-- ============================================================================
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


-- ============================================================================
-- TEST 6 — 06_verifications_isolation.sql   ⟵ RUN THIS BLOCK ON ITS OWN
-- ============================================================================
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


-- ============================================================================
-- TEST 7 — 07_audit_log_isolation.sql   ⟵ RUN THIS BLOCK ON ITS OWN
-- ============================================================================
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


-- ============================================================================
-- TEST 8 — 08_dues_isolation.sql   ⟵ RUN THIS BLOCK ON ITS OWN
-- ============================================================================
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


-- ============================================================================
-- STEP 99 — CLEANUP (run last)
-- ============================================================================
DROP SCHEMA IF EXISTS iso_test CASCADE;

-- Two further tests live in supabase/tests/ and can be pasted the same way:
--   document_pipeline_isolation_test.sql
--   grievance_tenant_isolation_test.sql
