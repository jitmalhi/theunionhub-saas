-- =============================================================================
-- 0034_lookup_steward.sql · Close the anonymous steward-PII exposure
-- =============================================================================
-- BEFORE: 0013's `stewards_public_read` granted anon a broad tenant-scoped
-- SELECT on the whole stewards table. Because tenant UUIDs are discoverable
-- (tenants is world-readable) and the policy is not row-limited, any anonymous
-- caller could enumerate EVERY steward of EVERY tenant and dump full_name,
-- email, phone, worksite, bio, plus internal ids (user_id, member_id,
-- created_by) — a complete steward roster harvest, platform-wide. For a union
-- product whose threat model includes hostile employers, that is unacceptable.
--
-- AFTER: anon has NO direct SELECT on stewards. The public /access and /meet
-- scan pages read a SINGLE steward by id through lookup_steward(p_id) — the
-- same shape as lookup_member (0008): SECURITY DEFINER, reads
-- get_request_tenant_id() itself, one row, tenant-scoped, and whitelists ONLY
-- the public card/vCard fields (never user_id / member_id / created_by /
-- tenant_id). Authenticated reads (steward self-view in the portal, admin
-- roster management) are UNCHANGED — the policy keeps `authenticated`.
--
-- Numbering: 0031 reserved (members RLS hardening); identity-security work 0034.
-- Depends on: 0008 (get_request_tenant_id, lookup_member pattern), 0013
--             (stewards + stewards_public_read), 0015 (stewards.role).
-- Idempotent. After applying: NOTIFY pgrst, 'reload schema';
-- =============================================================================

BEGIN;

-- ─── 1 · Remove anon from the direct table read ─────────────────────────────
-- Replace the anon+authenticated broad read with an authenticated-only read.
-- (Same predicate — only anon is dropped — so portal self-view and admin
-- roster reads behave exactly as before.)
DROP POLICY IF EXISTS stewards_public_read ON public.stewards;

CREATE POLICY stewards_tenant_read
  ON public.stewards
  FOR SELECT
  TO authenticated
  USING (tenant_id = public.get_request_tenant_id());

-- ─── 2 · lookup_steward(p_id) — anon-callable single-row fetch ──────────────
-- The only path anon has to stewards after this migration. No enumeration
-- (one id in, at most one row out), no cross-tenant (reads the header tenant
-- itself and filters server-side), no internal ids in the return shape.
CREATE OR REPLACE FUNCTION public.lookup_steward(p_id uuid)
RETURNS TABLE (
  id         uuid,
  full_name  text,
  title      text,
  role       text,
  email      text,
  phone      text,
  worksite   text,
  bio        text,
  photo_url  text,
  status     text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL OR p_id IS NULL THEN
    RETURN;  -- empty result; anon gets []
  END IF;

  RETURN QUERY
  SELECT s.id, s.full_name, s.title, s.role, s.email, s.phone,
         s.worksite, s.bio, s.photo_url, s.status
    FROM public.stewards s
   WHERE s.id = p_id
     AND s.tenant_id = v_tenant_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.lookup_steward(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.lookup_steward(uuid) TO anon, authenticated;

COMMENT ON POLICY stewards_tenant_read ON public.stewards IS
  'Tightened in 0034: authenticated-only (portal self-view + admin roster). '
  'anon must use lookup_steward(p_id) — no direct table read, no enumeration.';

COMMENT ON FUNCTION public.lookup_steward(uuid) IS
  'Single-steward lookup scoped to the current tenant, for the public /access '
  'and /meet scan pages. SECURITY DEFINER so anon can call it after this '
  'migration removes their direct SELECT. Returns only public card/vCard fields '
  '(id, full_name, title, role, email, phone, worksite, bio, photo_url, status) '
  '— never user_id, member_id, created_by, or tenant_id.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--   -- anon can no longer enumerate stewards directly (empty/denied even with
--   -- the right tenant header):
--   curl -s "$SUPABASE_URL/rest/v1/stewards?select=id,email" \
--        -H "apikey: $SUPABASE_ANON_KEY" -H "x-tenant-id: $TENANT_UUID"   -- []
--
--   -- anon single-steward lookup works and omits internal ids:
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/lookup_steward" \
--        -H "apikey: $SUPABASE_ANON_KEY" -H "x-tenant-id: $TENANT_UUID" \
--        -H "Content-Type: application/json" -d '{"p_id":"'$STEWARD_ID'"}'
--   -- → one row: full_name/title/role/email/phone/worksite/bio/photo_url/status
--
--   -- wrong tenant → empty:
--   curl ... -H "x-tenant-id: 00000000-0000-0000-0000-000000000000" ...   -- []
-- ════════════════════════════════════════════════════════════════════════════
