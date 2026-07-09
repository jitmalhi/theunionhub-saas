-- =============================================================================
-- 0033_lookup_member_add_member_number.sql
-- =============================================================================
-- Adds member_number to the public verification surface so the card can paint a
-- "Member No." row (harvested from member-id-system). This is the ONLY new
-- field exposed; it's already visible on any printed card, so no new PII
-- reaches anon. The security shape is unchanged from 0008:
--   · SECURITY DEFINER, reads get_request_tenant_id() ITSELF (caller can't spoof)
--   · single-row, tenant-scoped (no enumeration, no cross-tenant)
--   · anon's only path to members (they have no direct SELECT policy)
--
-- Depends on: 0008 (lookup_member), 0032 (members.member_number).
-- After applying: NOTIFY pgrst, 'reload schema';
--
-- NOTE: this adds member_number to the RETURNS TABLE (…) shape. Postgres forbids
-- CREATE OR REPLACE from changing a function's return type (SQLSTATE 42P13,
-- "cannot change return type of existing function"), so we DROP the 0008
-- signature first and CREATE it fresh. DROP also removes the function's grants,
-- so the REVOKE/GRANT re-assert below is required (not merely defensive).
-- =============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.lookup_member(uuid);

CREATE FUNCTION public.lookup_member(p_id uuid)
RETURNS TABLE (
  id            uuid,
  member_number text,
  full_name     text,
  union_name    text,
  local_number  text,
  member_since  date,
  status        text
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
  SELECT m.id, m.member_number, m.full_name, m.union_name,
         m.local_number, m.member_since, m.status
    FROM public.members m
   WHERE m.id = p_id
     AND m.tenant_id = v_tenant_id;
END;
$$;

-- The DROP above removed the grants from 0008, so these re-establish them.
REVOKE EXECUTE ON FUNCTION public.lookup_member(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.lookup_member(uuid) TO anon, authenticated;

COMMENT ON FUNCTION public.lookup_member(uuid) IS
  'Single-row member lookup scoped to the current tenant. SECURITY DEFINER so '
  'anon can call it (no direct members SELECT after 0008). Returns only the '
  'display fields card.html / verify.html paint — id, member_number, full_name, '
  'union_name, local_number, member_since, status. Never exposes PII columns '
  'added in 0023 (email, phone, employee_id, …).';

COMMIT;
