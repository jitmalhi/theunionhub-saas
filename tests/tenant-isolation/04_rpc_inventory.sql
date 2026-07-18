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
