-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0003 — public.public_stats() SECURITY DEFINER
-- ════════════════════════════════════════════════════════════════════════
-- Resolves the regression introduced by migration 0002:
--
--   The marketing site's "live stats strip" (js/live.js → fetchStats) counts
--   members and active tenants across the whole platform. After 0002 turned
--   on tenant-isolated RLS on public.members, anon requests with no
--   x-tenant-id header (which is the apex marketing page's situation by
--   design — the apex has no tenant) get 0 rows back. The counter pegs at
--   zero.
--
-- This function bypasses RLS to compute global aggregate counts, returns
-- only counts (never identifiers, names, or per-row data), and is locked
-- down so only anon / authenticated can call it.
--
-- Security model — SECURITY DEFINER tripwires we explicitly defuse:
--
--   1. The function runs as its OWNER (whoever ran the migration), so it
--      sees every row in every table it reads. Body returns aggregate
--      counts only — no row data, no tenant identifiers, no member PII.
--      Add aggregate fields here; never add anything that could leak per-
--      row or per-tenant breakdowns.
--
--   2. SET search_path = public, pg_temp pins lookups to the trusted
--      schema. Without this, a user who can create objects in any schema
--      on the search_path could shadow public.members with a malicious
--      view and intercept the function's queries.
--
--   3. REVOKE EXECUTE FROM PUBLIC strips the default grant that
--      CREATE FUNCTION gives. GRANT EXECUTE then opens it back up to
--      exactly the two roles that need it. service_role bypasses all of
--      this anyway.
--
--   4. STABLE + PARALLEL SAFE let the planner cache the result across
--      rows in a single statement and farm it out to parallel workers.
--      Both are safe for read-only COUNT functions.
--
-- Prerequisites: migration 0001 (tenants). 0002 (members + tenant_id) is
-- optional — the function falls back to 0 if members doesn't exist yet.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.public_stats()
RETURNS TABLE (
  members_count        bigint,
  locals_count         bigint,
  verifications_today  bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
STABLE
PARALLEL SAFE
AS $$
DECLARE
  v_members             bigint;
  v_locals              bigint;
  v_verifications_today bigint;
BEGIN
  -- Members: count rows that belong to ACTIVE tenants only. Members of
  -- archived / suspended tenants shouldn't inflate the marketing number
  -- the way a raw COUNT(*) FROM members would. Defensive against the
  -- members table not existing yet (database where 0002 hasn't run).
  BEGIN
    SELECT COUNT(*) INTO v_members
      FROM public.members m
      JOIN public.tenants t ON t.id = m.tenant_id
     WHERE t.status = 'active';
  EXCEPTION WHEN undefined_table THEN
    v_members := 0;
  END;

  -- Locals: active tenants only. tenants always exists (0001 prerequisite),
  -- so no EXCEPTION block needed here.
  SELECT COUNT(*) INTO v_locals
    FROM public.tenants
   WHERE status = 'active';

  -- Verifications today: defensive against verifications table not yet
  -- existing (it lands in a future migration). Returns 0 until that
  -- ships, then starts returning real counts WITHOUT needing to edit
  -- or redeploy this function — the EXCEPTION block stops catching
  -- once the table exists.
  BEGIN
    SELECT COUNT(*) INTO v_verifications_today
      FROM public.verifications
     WHERE created_at >= current_date;
  EXCEPTION WHEN undefined_table THEN
    v_verifications_today := 0;
  END;

  RETURN QUERY SELECT v_members, v_locals, v_verifications_today;
END;
$$;

-- ─── Lockdown ────────────────────────────────────────────────────────────
-- CREATE FUNCTION grants EXECUTE to PUBLIC by default. Strip that grant,
-- then re-grant explicitly to the two roles allowed to call this.
REVOKE EXECUTE ON FUNCTION public.public_stats() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.public_stats() TO anon, authenticated;

COMMENT ON FUNCTION public.public_stats() IS
  'Returns GLOBAL aggregate counts safe to expose anonymously: members of '
  'active tenants, count of active tenants, verifications today. SECURITY '
  'DEFINER bypasses RLS so the marketing site (no tenant context) sees '
  'real numbers. Returns ONLY counts — never identifiers, names, or row '
  'data. Add aggregate fields here; never add any field that exposes per-'
  'row or per-tenant breakdowns.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- The function exists with the expected signature?
--   \df+ public.public_stats
--
--   -- Anon can call it; service role can too:
--   curl -s "$SUPABASE_URL/rest/v1/rpc/public_stats" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--   # → [{"members_count":3,"locals_count":1,"verifications_today":0}]
--
--   -- Anon WITHOUT any tenant header gets the same numbers (the whole
--   -- point — no x-tenant-id required, this is the apex code path):
--   curl -s "$SUPABASE_URL/rest/v1/rpc/public_stats" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--
--   -- And cross-check that anon STILL can't read individual member rows
--   -- (so the function is the only authorised window into members from
--   -- the apex):
--   curl -s "$SUPABASE_URL/rest/v1/members?select=id&limit=1" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--   # → []
--
-- Known follow-ups:
--   · Materialised view + cron refresh once member counts climb into the
--     hundreds of thousands and COUNT(*) becomes hot-path expensive.
--   · Per-tenant counterpart tenant_stats(p_tenant_id uuid) called by
--     the future admin app. That one is SECURITY INVOKER + checks
--     x-tenant-id matches the arg.
-- ════════════════════════════════════════════════════════════════════════
