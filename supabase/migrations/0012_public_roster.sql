-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0012 — public.public_roster() RPC
-- ════════════════════════════════════════════════════════════════════════
-- Restores the marketing site's "live roster" strip. Same problem as
-- the public_stats regression that 0003 fixed — when 0008 tightened
-- members RLS to require tenant_admins, anon visitors to the apex
-- (no tenant context, no admin session) could no longer SELECT any
-- members. The js/live.js fetchRoster hit /rest/v1/members?id=in.(…)
-- and got [] back; the page degraded to whatever static HTML was in
-- the [data-live-roster] container.
--
-- The fix mirrors public_stats: a SECURITY DEFINER RPC that bypasses
-- RLS to read members, returning ONLY the demo tenant's members
-- (which are explicitly seeded as showcase data — see seed.sql) and
-- ONLY the display fields the marketing-site strip paints.
--
-- Security tripwires defused (same set public_stats handles):
--
--   1. SECURITY DEFINER lets the function see members rows that the
--      caller cannot. The body is scoped so anon only ever gets the
--      demo tenant's members — never any real union's roster.
--
--   2. SET search_path = public, pg_temp pins lookups to the trusted
--      schema; a malicious shadow view in another schema can't
--      intercept the SELECT.
--
--   3. REVOKE EXECUTE FROM PUBLIC + GRANT to anon, authenticated.
--      service_role bypasses RLS and EXECUTE grants entirely.
--
--   4. STABLE + PARALLEL SAFE — function is read-only, deterministic
--      within a statement.
--
--   5. Result capped at 50 rows — prevents anyone from enumerating
--      the full demo roster via a runaway p_limit. The marketing
--      strip only renders ~3 rows anyway.
--
-- Prerequisites: 0001 (tenants), 0002 (members + tenant_id).
-- Tolerates 0002 not being applied (members table missing → returns
-- empty rather than raising).
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.public_roster(p_limit int DEFAULT 10)
RETURNS TABLE (
  id            uuid,
  full_name     text,
  status        text,
  member_since  date
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
STABLE
PARALLEL SAFE
AS $$
DECLARE
  v_demo_tenant_id uuid;
  v_cap            int;
BEGIN
  -- Clamp the requested limit between 1 and 50. A pathological request
  -- with p_limit = 100000 can't enumerate the demo tenant's full roster;
  -- a missing or negative value still returns something useful.
  v_cap := GREATEST(1, LEAST(COALESCE(p_limit, 10), 50));

  -- Resolve the demo tenant. If it doesn't exist (very early scaffold,
  -- before seed.sql ran) or has been archived, return empty silently —
  -- a failed marketing-page widget should never raise.
  SELECT t.id INTO v_demo_tenant_id
    FROM public.tenants t
   WHERE t.slug = 'demo' AND t.status = 'active'
   LIMIT 1;

  IF v_demo_tenant_id IS NULL THEN
    RETURN;
  END IF;

  -- Order for visual stability: status priority (active → inactive →
  -- suspended → pending → other), then alphabetical. The marketing
  -- strip renders rows in this exact order without further sorting.
  BEGIN
    RETURN QUERY
      SELECT m.id, m.full_name, m.status, m.member_since
        FROM public.members m
       WHERE m.tenant_id = v_demo_tenant_id
       ORDER BY
         CASE m.status
           WHEN 'active'    THEN 0
           WHEN 'inactive'  THEN 1
           WHEN 'suspended' THEN 2
           WHEN 'pending'   THEN 3
           ELSE              4
         END,
         m.full_name ASC
       LIMIT v_cap;
  EXCEPTION WHEN undefined_table THEN
    -- members table doesn't exist yet (pre-0002). Same silent-empty
    -- pattern as public_stats uses for verifications.
    RETURN;
  END;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.public_roster(int) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.public_roster(int) TO anon, authenticated;

COMMENT ON FUNCTION public.public_roster(int) IS
  'Returns a curated list of demo tenant members for the marketing site''s '
  'live-roster strip. SECURITY DEFINER so anon can call it after 0008 '
  'removed direct SELECT on members. Returns ONLY id + full_name + status '
  '+ member_since for the ''demo'' tenant — never other tenants, never '
  'fields like email or notes. Capped at 50 rows. The demo tenant''s '
  'members are showcase data by design (seed.sql).';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Anon call:
--   curl -s "$SUPABASE_URL/rest/v1/rpc/public_roster" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--   -- Expect: [{"id":"550bc413…","full_name":"Demo Member · Active",
--   --           "status":"active","member_since":null}, …]
--
--   -- With limit:
--   curl -s "$SUPABASE_URL/rest/v1/rpc/public_roster?p_limit=2" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--
--   -- Pathological limit gets clamped:
--   curl -s "$SUPABASE_URL/rest/v1/rpc/public_roster?p_limit=99999" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--   -- Expect: still capped at 50 rows
--
--   -- Cross-check: anon STILL can't read members directly (0008 lock
--   -- intact, RPC is the only narrow window):
--   curl -s "$SUPABASE_URL/rest/v1/members?select=id" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--   -- Expect: []
--
-- Known follow-ups:
--   · A `showcase` flag on members so the marketing strip can include
--     curated rows from non-demo tenants who opt in (e.g., an early
--     real local that's happy to be featured).
--   · A materialized view backing this RPC if the marketing site ever
--     becomes high-traffic enough that the per-call query matters.
-- ════════════════════════════════════════════════════════════════════════
