-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub Access · Migration 0016 — role-escalation guard trigger
-- ════════════════════════════════════════════════════════════════════════
-- Closes the self-edit escalation vector flagged in migration 0015 at the
-- DATABASE, not only in the app. For a credential whose entire value is trust,
-- the UI must not be the only thing standing between a rank-and-file steward
-- and a forged 'executive' tier.
--
-- The vector (recap from 0013 + 0015):
--   0013's stewards_admin_or_self_update lets a LINKED steward UPDATE their own
--   row; its WITH CHECK only pins tenant_id + user_id, so it does not constrain
--   WHICH columns change. The portal keeps `role` out of its editable set
--   (app-layer guard), but a hand-crafted PATCH straight to PostgREST —
--   `PATCH /rest/v1/stewards?id=eq.<own-id>  { "role": "executive" }` — would
--   otherwise satisfy RLS and succeed. This trigger makes the database reject
--   it regardless of client.
--
-- The rule:
--   On UPDATE, if `role` actually changes, allow it ONLY for a tenant admin.
--   A non-admin authenticated caller (the self-edit path) is rejected.
--
-- Who is affected — and deliberately who is NOT:
--   · authenticated tenant admin   → is_request_tenant_admin() = true  → ALLOW.
--     (The admin console binds x-tenant-id via the tenant-scoped client, so the
--     admin gate resolves; managing tiers keeps working.)
--   · authenticated self-edit rep  → auth.uid() set, not an admin     → BLOCK.
--   · service_role (server tooling)→ auth.uid() IS NULL               → ALLOW.
--     service_role bypasses RLS but NOT triggers; gating on auth.uid() IS NULL
--     lets trusted server code (and future admin tooling / backfills) set roles
--     without tripping the guard. No current server path changes role —
--     claim_representative() (0014) only writes user_id — but this keeps the
--     door open for one without a follow-up migration.
--   · anon                         → has no UPDATE policy (0013)       → never
--     reaches this trigger.
--
-- Note: the check is on a genuine CHANGE (IS DISTINCT FROM), so a self-edit
-- PATCH that merely echoes the current role value is not rejected. The portal
-- doesn't send `role` at all, so the normal self-edit flow is untouched.
--
-- SECURITY DEFINER with a pinned search_path, mirroring the 0006/0014
-- convention, so is_request_tenant_admin() and auth.uid() resolve under a
-- controlled path with no hijack surface.
--
-- Prerequisites: 0008 (is_request_tenant_admin), 0013 (stewards),
--                0015 (stewards.role).
--
-- Idempotency: CREATE OR REPLACE FUNCTION; trigger is DROP … IF EXISTS then
-- CREATE. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ─── 1 · guard function ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.enforce_steward_role_admin_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
BEGIN
  -- Only care when the tier actually changes.
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    -- service_role / trusted server context has no end-user JWT → auth.uid()
    -- is NULL → permitted. An authenticated end-user must be a tenant admin.
    IF auth.uid() IS NOT NULL AND NOT public.is_request_tenant_admin() THEN
      RAISE EXCEPTION 'role_change_not_permitted'
        USING HINT = 'Only a union administrator can change a representative''s '
                  || 'credential tier (role). Contact your admin.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enforce_steward_role_admin_only() IS
  'BEFORE UPDATE guard on public.stewards: rejects a change to `role` by any '
  'authenticated non-admin (the self-edit path), closing the credential-tier '
  'escalation vector left open by 0013 RLS. Permits tenant admins and '
  'service_role (auth.uid() IS NULL). Fires only on a genuine role change.';


-- ─── 2 · trigger ────────────────────────────────────────────────────────
-- BEFORE UPDATE only: INSERT is already admin-gated by 0013
-- (stewards_admin_insert WITH CHECK is_request_tenant_admin()), so a forged
-- tier can't enter on create either. Co-exists with stewards_set_updated_at
-- (0013); firing order is irrelevant — this trigger inspects role only.
DROP TRIGGER IF EXISTS stewards_guard_role_change ON public.stewards;
CREATE TRIGGER stewards_guard_role_change
  BEFORE UPDATE ON public.stewards
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_steward_role_admin_only();


COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Function + trigger exist:
--   SELECT tgname, tgenabled FROM pg_trigger
--    WHERE tgrelid = 'public.stewards'::regclass
--      AND tgname = 'stewards_guard_role_change';
--   -- Expect one row, tgenabled = 'O' (enabled).
--
--   -- Negative test (as an authenticated, NON-admin steward whose own row it
--   -- is, x-tenant-id = their tenant):
--   --   UPDATE public.stewards SET role = 'executive' WHERE user_id = auth.uid();
--   --   → ERROR: role_change_not_permitted
--
--   -- Self-edit of an allowed field still works (role unchanged):
--   --   UPDATE public.stewards SET bio = 'Day shift, Plant 2.' WHERE user_id = auth.uid();
--   --   → 1 row.
--
--   -- Admin promotion works (authenticated tenant admin, x-tenant-id set):
--   --   UPDATE public.stewards SET role = 'unit_officer' WHERE id = '…';
--   --   → 1 row.
--
--   -- Echoing the same value is not blocked (IS DISTINCT FROM):
--   --   UPDATE public.stewards SET role = role WHERE user_id = auth.uid();
--   --   → 1 row (no actual change).
--
-- Known follow-ups (separate slices):
--   · audit_log entry on role changes once stewards has audit hooks — pair the
--     guard (who MAY change) with a record (who DID change).
--   · If a future server path must let service_role be denied too, tighten the
--     auth.uid() IS NULL allowance to an explicit service-role check.
-- ════════════════════════════════════════════════════════════════════════
