-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0041 — tenant-scope the admin RLS policies
-- ════════════════════════════════════════════════════════════════════════
-- SECURITY REMEDIATION (not a feature). Closes a confirmed cross-tenant
-- isolation gap surfaced by the tenant-isolation suite (tests/tenant-isolation/)
-- and a full policy audit across migrations 0001–0040.
--
-- ── Root cause ──────────────────────────────────────────────────────────
-- Several admin-gated policies gate ONLY on public.is_request_tenant_admin()
-- (or is_request_tenant_member()) in their row-visibility clause (USING).
-- Those helpers are per-REQUEST booleans — is_tenant_admin(get_request_tenant_id(),
-- auth.uid()) — NOT per-row. So once a caller is an admin of the tenant named in
-- the x-tenant-id header, the USING is true for EVERY row, across ALL tenants.
--
-- Consequence: an authenticated admin of Tenant A could
--   · READ every tenant's rows (members, verifications, dues, audit_log),
--   · DELETE any tenant's members / stewards,
--   · and — via UPDATE, whose WITH CHECK only forces the FINAL tenant_id = A —
--     REASSIGN another tenant's member into their own tenant (takeover).
-- INSERT was already safe (its WITH CHECK pins tenant_id = get_request_tenant_id()).
--
-- ── Affected policies (from the audit; the ONLY ones matching the pattern) ──
--   members.members_admin_read        (SELECT) — USING boolean-only
--   members.members_admin_update      (UPDATE) — USING boolean-only
--   members.members_admin_delete      (DELETE) — USING boolean-only
--   verifications.verifications_admin_read (SELECT) — USING boolean-only
--   dues_collections.dues_admin_read  (SELECT) — USING boolean-only
--   audit_log.audit_log_admin_read    (SELECT) — USING boolean-only
--   stewards.stewards_admin_delete    (DELETE) — USING boolean-only
-- (All other tenant-scoped policies already include tenant_id = get_request_tenant_id().
--  Storage policies use a path-based mechanism and are reviewed separately.)
--
-- ── Corrective action ───────────────────────────────────────────────────
-- Add `AND tenant_id = public.get_request_tenant_id()` to each USING clause, so
-- row visibility requires BOTH "is admin of the header tenant" AND "the row
-- belongs to the header tenant". WITH CHECK clauses already carry the tenant
-- filter and are left unchanged. Uses ALTER POLICY (surgical; no drop/recreate).
--
-- The enforced model becomes:
--   1. Authentication  → who the user is (auth.uid()).
--   2. Tenant context  → which org (x-tenant-id → get_request_tenant_id()).
--   3. RLS             → which rows (tenant_id must match, per row).
-- A tenant admin can never touch another tenant's rows.
--
-- Prerequisites: 0008 (members/verifications/dues/audit admin policies),
--                0013 (stewards_admin_delete).
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── members ─────────────────────────────────────────────────────────────
ALTER POLICY members_admin_read ON public.members
  USING (public.is_request_tenant_admin()
         AND tenant_id = public.get_request_tenant_id());

ALTER POLICY members_admin_update ON public.members
  USING (public.is_request_tenant_admin()
         AND tenant_id = public.get_request_tenant_id());
-- (WITH CHECK on members_admin_update already pins tenant_id = get_request_tenant_id())

ALTER POLICY members_admin_delete ON public.members
  USING (public.is_request_tenant_admin()
         AND tenant_id = public.get_request_tenant_id());

-- ── verifications ───────────────────────────────────────────────────────
ALTER POLICY verifications_admin_read ON public.verifications
  USING (public.is_request_tenant_admin()
         AND tenant_id = public.get_request_tenant_id());

-- ── dues_collections ────────────────────────────────────────────────────
ALTER POLICY dues_admin_read ON public.dues_collections
  USING (public.is_request_tenant_admin()
         AND tenant_id = public.get_request_tenant_id());

-- ── audit_log ───────────────────────────────────────────────────────────
ALTER POLICY audit_log_admin_read ON public.audit_log
  USING (public.is_request_tenant_admin()
         AND tenant_id = public.get_request_tenant_id());

-- ── stewards ────────────────────────────────────────────────────────────
ALTER POLICY stewards_admin_delete ON public.stewards
  USING (public.is_request_tenant_admin()
         AND tenant_id = public.get_request_tenant_id());

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Verification (run the isolation suite against a DB with 0001–0041 applied):
--   tests/tenant-isolation/run_isolation_tests.sh
-- Expected AFTER 0041:
--   · 01_members_isolation.sql   PASS  (A cannot read/delete B members)
--   · 02_negative_context.sql    PASS  (cross-tenant UPDATE/DELETE blocked; reassignment fails)
--   · 03_grievance_isolation.sql PASS  (was already correct)
--   · 04_rpc_inventory.sql       PASS  (DEFINER hardening + lookup_member scope)
-- Expected BEFORE 0041 (baseline 0001–0040): 01 and 02 FAIL, proving the gap.
--
-- No data migration; policy-only change; rollback = restore pre-apply snapshot
-- OR re-ALTER the USING clauses back (not advised — that re-opens the leak).
-- ════════════════════════════════════════════════════════════════════════
