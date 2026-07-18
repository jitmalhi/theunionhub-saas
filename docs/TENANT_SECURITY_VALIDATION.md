# TENANT SECURITY VALIDATION

**Status:** 🔴 **NOT VALIDATED — isolation gate OPEN.** Awaiting a database environment.
**Branch:** `release/v0.1-production-hardening` · **Migration under test:** `0041_tenant_scope_admin_policies.sql` (authored, **not applied**).

> This document is a **checklist prepared in advance**. The result tables below are **PENDING** — they must be filled with **observed** output from an actual run. Do **not** mark any result PASS/FAIL from expectation; only from what the suite prints. The Security Model phase (`SECURITY_MODEL.md`) stays **blocked** until every row below is observed and this banner flips to ✅ VALIDATED.

---

## 1 · What this run proves
The confirmed cross-tenant gap (per `TENANT_ISOLATION_TESTING.md §4/§7`) is closed by `0041`. Proof requires observing the suite behave **differently before and after** the fix:
- **Baseline `0001–0040`:** the security tests must **detect the vulnerability** (the gap-catching tests FAIL). If they pass at baseline, the tests are not actually testing the gap — investigate before trusting them.
- **Fixed `0001–0041`:** every isolation test **passes**.

## 2 · Safety (hard rules)
- Run against a **clean, disposable test database** (local `supabase start`, scratch project, or staging). **NEVER production.**
- The runner refuses the production project ref; do not set `ISOLATION_ALLOW_PROD`.
- All suite tests are transactional (`ROLLBACK`) + drop the `iso_test` fixture schema — no residue.

## 3 · Environment prerequisites
- Docker Desktop running (for `supabase start`) **or** access to a scratch/staging Postgres.
- `npx --no-install supabase` (CLI 2.109.0) run from `C:\X\steward-system`.
- `DATABASE_URL` for the test DB (local default: `postgres://postgres:postgres@localhost:54322/postgres`).

## 4 · Procedure

### Step A — provision a clean test DB
```bash
cd C:\X\steward-system
npx --no-install supabase start           # local Postgres+Auth (Docker)
```

### Step B — BASELINE (0001–0040): confirm the tests DETECT the vulnerability
Temporarily exclude the fix, apply through 0040, run the suite:
```bash
mkdir -p .tmp && mv supabase/migrations/0041_tenant_scope_admin_policies.sql .tmp/
npx --no-install supabase db reset        # applies 0001-0040 only
DATABASE_URL='postgres://postgres:postgres@localhost:54322/postgres' \
  ./tests/tenant-isolation/run_isolation_tests.sh | tee validation-baseline.txt
```
**Expected:** `01_members`, `02_negative_context`, `05_stewards` **FAIL** (gap detected); `03/04` + the 4 existing tests **PASS**. Record in Table 6.1.

### Step C — FIXED (0001–0041): confirm the fix CLOSES the gap
Restore the fix, re-apply, run again:
```bash
mv .tmp/0041_tenant_scope_admin_policies.sql supabase/migrations/ && rmdir .tmp
npx --no-install supabase db reset        # applies 0001-0041
DATABASE_URL='postgres://postgres:postgres@localhost:54322/postgres' \
  ./tests/tenant-isolation/run_isolation_tests.sh | tee validation-fixed.txt
```
**Expected:** **all tests PASS.** Record in Table 6.1.

## 5 · Coverage note — RESOLVED
Every table touched by `0041` now has **dedicated automated coverage**:
- `06_verifications_isolation.sql` — verifications
- `07_audit_log_isolation.sql` — audit_log
- `08_dues_isolation.sql` — dues_collections *(exists in the active schema — 0004 + 0010 — so a test is present, not a documented absence)*

There is no longer any "fixed-but-untested" table in the remediation set. All that remains is to **observe** the results by running the suite against a real database (§4).

## 6 · Observed results (PENDING — fill from the run)

### 6.1 Per-test (paste the runner's ✅/❌ line)
| Test | Expected @0040 | Observed @0040 | Expected @0041 | Observed @0041 |
|---|---|---|---|---|
| `01_members_isolation` | FAIL | ⬜ PENDING | PASS | ⬜ PENDING |
| `02_negative_context` | FAIL | ⬜ PENDING | PASS | ⬜ PENDING |
| `03_grievance_isolation` | PASS | ⬜ PENDING | PASS | ⬜ PENDING |
| `04_rpc_inventory` | PASS | ⬜ PENDING | PASS | ⬜ PENDING |
| `05_stewards_isolation` | FAIL | ⬜ PENDING | PASS | ⬜ PENDING |
| `06_verifications_isolation` | FAIL | ⬜ PENDING | PASS | ⬜ PENDING |
| `07_audit_log_isolation` | FAIL | ⬜ PENDING | PASS | ⬜ PENDING |
| `08_dues_isolation` | FAIL | ⬜ PENDING | PASS | ⬜ PENDING |
| `member_verify_isolation_test` | PASS | ⬜ PENDING | PASS | ⬜ PENDING |
| `steward_lookup_isolation_test` | PASS | ⬜ PENDING | PASS | ⬜ PENDING |
| `document_pipeline_isolation_test` | PASS | ⬜ PENDING | PASS | ⬜ PENDING |
| `grievance_tenant_isolation_test` | PASS | ⬜ PENDING | PASS | ⬜ PENDING |

### 6.2 Category acceptance (from the observed @0041 column)
| Category | Backed by | Status |
|---|---|---|
| Members isolation | `01_members` | ⬜ PENDING |
| Negative context | `02_negative_context` | ⬜ PENDING |
| Grievance isolation | `03_grievance`, `grievance_tenant` | ⬜ PENDING |
| Credential isolation | `member_verify` | ⬜ PENDING |
| Document isolation (rows) | `document_pipeline` | ⬜ PENDING |
| Steward isolation | `05_stewards`, `steward_lookup` | ⬜ PENDING |
| RPC security | `04_rpc_inventory` | ⬜ PENDING |
| Verification isolation | `06_verifications_isolation` | ⬜ PENDING |
| Audit isolation | `07_audit_log_isolation` | ⬜ PENDING |
| Dues isolation | `08_dues_isolation` | ⬜ PENDING |

## 7 · Sign-off (fill on completion)
- Run by: ____________  · Date (UTC): ____________
- Test DB: ____________ (confirm NOT production)
- Suite commit SHA: ____________  · `0041` present: ☐
- Baseline detected the gap (01/02/05 FAIL @0040): ☐
- All tests PASS @0041: ☐  · §5 coverage gap resolved (tests added or code-review signed): ☐
- **Gate result:** ☐ VALIDATED — flip the top banner to ✅ and unblock `SECURITY_MODEL.md` · ☐ NOT validated (reason: __________)

---
_Until §7 is complete with observed results, the isolation gate is OPEN and the Security Model phase stays blocked. Prepared 2026-07-16; results pending a database environment._
