-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub Access · Migration 0014 — claim_representative() RPC
-- ════════════════════════════════════════════════════════════════════════
-- Additive only. No table or column is renamed or dropped — the 0013 schema
-- names (stewards / steward_analytics / steward_id) stay frozen, per the
-- product decision. This migration adds ONE SECURITY DEFINER function that
-- powers the representative self-portal's "claim your profile" step.
--
-- Why an RPC is required (and a plain client UPDATE is not):
--   Reps are pre-created by an admin with user_id IS NULL and a permanent
--   QR already printed (migration 0013, by design). On first magic-link
--   login the rep must link their identity by setting user_id = auth.uid().
--   But the self-update RLS policy from 0013, stewards_admin_or_self_update,
--   has USING:
--       is_request_tenant_admin()
--       OR (user_id = auth.uid() AND tenant_id = get_request_tenant_id())
--   On an unclaimed row user_id IS NULL, so `NULL = auth.uid()` is NULL
--   (false), and the rep is not an admin — the UPDATE is rejected. There is
--   intentionally no client path to flip user_id on someone else's (or a
--   nobody's) row. This function is that path, gated by an email match.
--
-- Security model (mirrors is_tenant_admin / add_tenant_admin from 0006):
--   · SECURITY DEFINER so it can read auth.users.email (authenticated users
--     cannot read auth.users directly) and write user_id under RLS.
--   · Tenant scope is taken from get_request_tenant_id() (the x-tenant-id
--     header), never from a caller argument — a rep on union A can never
--     claim a row in union B.
--   · The match is: an UNCLAIMED rep (user_id IS NULL) in the caller's
--     tenant whose stewards.email equals the caller's verified auth email.
--     No email on the row → not claimable (admin must set it first).
--   · Idempotent: if the caller already owns a row in this tenant, it is
--     returned unchanged.
--   · Race-safe: the candidate row is locked FOR UPDATE; a concurrent claim
--     re-evaluates user_id IS NULL after the lock and finds nothing.
--   · REVOKE FROM PUBLIC, GRANT TO authenticated (anon cannot claim).
--
-- Prerequisites: 0001 (tenants), 0002 (get_request_tenant_id),
--                0013 (stewards + stewards_admin_or_self_update).
--
-- Idempotency: CREATE OR REPLACE; safe to re-run.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.claim_representative()
RETURNS public.stewards
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id uuid;
  v_uid       uuid;
  v_email     text;
  v_row       public.stewards%ROWTYPE;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context'
      USING HINT = 'Open the portal from your union''s address (x-tenant-id missing).';
  END IF;

  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  -- 1 · Already linked in this tenant? Idempotent: return the existing row.
  SELECT * INTO v_row
    FROM public.stewards
   WHERE tenant_id = v_tenant_id
     AND user_id   = v_uid
   LIMIT 1;
  IF FOUND THEN
    RETURN v_row;
  END IF;

  -- 2 · Resolve the caller's verified email from auth.users.
  SELECT lower(email) INTO v_email FROM auth.users WHERE id = v_uid;
  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'no_email_on_account';
  END IF;

  -- 3 · Find an unclaimed rep in THIS tenant whose email matches. Lock it so
  --     two simultaneous claims can't both win (the loser re-checks
  --     user_id IS NULL after the lock releases and finds nothing).
  SELECT * INTO v_row
    FROM public.stewards
   WHERE tenant_id = v_tenant_id
     AND user_id IS NULL
     AND email IS NOT NULL
     AND lower(email) = v_email
   ORDER BY created_at
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_claimable_representative'
      USING HINT = 'No unclaimed representative in this union matches your '
                 || 'email. Ask your admin to add you, or to correct the '
                 || 'email on file, then sign in again.';
  END IF;

  -- 4 · Link identity permanently.
  UPDATE public.stewards
     SET user_id    = v_uid,
         updated_at = NOW()
   WHERE id = v_row.id
   RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.claim_representative() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.claim_representative() TO authenticated;

COMMENT ON FUNCTION public.claim_representative() IS
  'Self-service claim: links the authenticated caller (auth.uid()) to an '
  'unclaimed stewards row in the request tenant whose email matches the '
  'caller''s verified auth email, by setting user_id. Idempotent, '
  'tenant-scoped via get_request_tenant_id(), race-safe (FOR UPDATE). '
  'SECURITY DEFINER — the only path to flip user_id on a pre-created rep, '
  'since 0013 RLS blocks a client UPDATE of an unclaimed (user_id IS NULL) '
  'row. Powers /access/portal.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Function exists, DEFINER, authenticated-only:
--   SELECT proname, prosecdef FROM pg_proc WHERE proname = 'claim_representative';
--   -- Expect prosecdef = t.
--
--   -- End-to-end (as an authenticated rep, x-tenant-id = their tenant):
--   --   precondition: a stewards row exists with user_id IS NULL and
--   --   email = <the email they signed in with>.
--   SELECT public.claim_representative();
--   -- Expect: the now-linked row (user_id populated). Re-running returns the
--   -- same row unchanged (idempotent).
--
--   -- Wrong email / already-claimed elsewhere:
--   --   raises no_claimable_representative.
--
--   -- After claim, the rep can self-edit via the normal RLS path:
--   UPDATE public.stewards SET title = 'Chief Shop Steward' WHERE user_id = auth.uid();
--   -- Expect: 1 row (stewards_admin_or_self_update now permits it).
--
-- Known follow-ups (separate slices):
--   · Optional: log claims to audit_log once stewards has audit integration.
--   · Optional: admin RPC to UNLINK a rep (set user_id = NULL) for offboarding
--     / re-issuing a claim to a different account.
-- ════════════════════════════════════════════════════════════════════════
