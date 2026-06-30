-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0019 — transfer_knowledge_entry() RPC
-- ════════════════════════════════════════════════════════════════════════
-- Hands a knowledge_entries row to another steward in the same union, by
-- reassigning user_id. This MUST be a SECURITY DEFINER function: the 0018 RLS
-- update policy requires the row to stay owned by the caller (or an admin), so
-- a plain client UPDATE that sets user_id to SOMEONE ELSE is rejected by design.
-- This function is the only sanctioned path — mirrors claim_representative (0014).
--
-- Security model:
--   · authenticated only (REVOKE PUBLIC, GRANT authenticated).
--   · Tenant scope from get_request_tenant_id() (x-tenant-id header), never an
--     argument — you can only act within your own union.
--   · Authorisation to transfer: the caller must OWN the entry
--     (user_id = auth.uid()) OR be a tenant admin. (Same gate as 0018 update.)
--   · The TARGET must be a CLAIMED steward in the SAME tenant whose
--     stewards.email matches p_target_email — so an entry can't be flung to an
--     arbitrary user or across the tenant boundary, and only to someone who has
--     actually signed in (user_id IS NOT NULL).
--   · Race-safe: the entry is locked FOR UPDATE before the ownership check.
--
-- After a successful transfer the original owner loses access (0018 SELECT
-- requires user_id = auth.uid() or admin) — which is the point: it leaves their
-- list and appears in the recipient's.
--
-- Prerequisites: 0002 (get_request_tenant_id), 0008 (is_request_tenant_admin),
--                0013 (stewards), 0018 (knowledge_entries).
-- Idempotency: CREATE OR REPLACE; safe to re-run.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.transfer_knowledge_entry(
  p_entry_id     uuid,
  p_target_email text
)
RETURNS public.knowledge_entries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id  uuid;
  v_uid        uuid;
  v_email      text;
  v_target_uid uuid;
  v_row        public.knowledge_entries%ROWTYPE;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context'
      USING HINT = 'Open the portal from your union''s address.';
  END IF;

  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  v_email := lower(trim(coalesce(p_target_email, '')));
  IF v_email = '' THEN
    RAISE EXCEPTION 'target_email_required';
  END IF;

  -- 1 · Lock the entry; it must live in the caller's tenant.
  SELECT * INTO v_row
    FROM public.knowledge_entries
   WHERE id = p_entry_id
     AND tenant_id = v_tenant_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'entry_not_found';
  END IF;

  -- 2 · Caller must own it, or be a tenant admin.
  IF NOT (v_row.user_id = v_uid OR public.is_request_tenant_admin()) THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  -- 3 · Resolve the target: a CLAIMED steward in THIS tenant whose email
  --     matches. user_id IS NOT NULL means they've signed in and can own a row.
  SELECT s.user_id INTO v_target_uid
    FROM public.stewards s
   WHERE s.tenant_id = v_tenant_id
     AND s.user_id IS NOT NULL
     AND s.email IS NOT NULL
     AND lower(s.email) = v_email
   ORDER BY s.created_at
   LIMIT 1;
  IF v_target_uid IS NULL THEN
    RAISE EXCEPTION 'target_not_a_steward'
      USING HINT = 'The recipient must be a representative in your union who has signed in at least once.';
  END IF;

  IF v_target_uid = v_row.user_id THEN
    RAISE EXCEPTION 'already_owned_by_target';
  END IF;

  -- 4 · Reassign ownership.
  UPDATE public.knowledge_entries
     SET user_id    = v_target_uid,
         updated_at = NOW()
   WHERE id = v_row.id
   RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.transfer_knowledge_entry(uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.transfer_knowledge_entry(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.transfer_knowledge_entry(uuid, text) IS
  'Reassigns a knowledge_entries row to another claimed steward in the same '
  'tenant (matched by stewards.email). Caller must own the entry or be a tenant '
  'admin; tenant-scoped via get_request_tenant_id(); race-safe (FOR UPDATE). '
  'SECURITY DEFINER — the only path to change user_id, since 0018 RLS blocks a '
  'client from reassigning ownership. Powers the Knowledge Capture transfer.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--   SELECT proname, prosecdef FROM pg_proc WHERE proname = 'transfer_knowledge_entry';
--   -- prosecdef = t
--
--   -- As the owner (x-tenant-id = their tenant), target = a signed-in steward's email:
--   SELECT public.transfer_knowledge_entry('<entry-uuid>', 'other.steward@union.org');
--   -- → the row, now owned by the target. It vanishes from the caller's list.
--
--   -- Error codes: no_tenant_context, not_authenticated, target_email_required,
--   --   entry_not_found, not_authorized, target_not_a_steward, already_owned_by_target.
--
-- Known follow-ups: optional audit_log row on transfer; allow transfer to a
-- tenant admin who isn't a steward; notify the recipient by email.
-- ════════════════════════════════════════════════════════════════════════
