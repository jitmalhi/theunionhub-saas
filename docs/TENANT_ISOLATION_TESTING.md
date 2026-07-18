# TENANT ISOLATION TESTING — The Union Hub

**Phase 3 (author)** · 2026-07-16 · Branch `release/v0.1-production-hardening`
The permanent security framework that proves tenant boundaries hold. Suite lives in `tests/tenant-isolation/`; this document is the *why*, the *coverage*, the *findings*, and the *rules for future tables*.

---

## 1 · Why tenant isolation matters (most of all)
The Union Hub is one database serving many locals. A single cross-tenant leak — Local A's officer seeing Local B's grievances, member PII, or documents — is not a bug, it is an **existential breach of trust** in a domain built on confidentiality (grievances are legally sensitive; members' data is private). No other correctness issue outranks this. The goal, stated plainly:

> A user, a compromised session, an incorrect query, or an accidental code change **must not** expose another tenant's information.

This must be *proven repeatedly and automatically*, not assumed once.

## 2 · Architecture assumptions (what isolation rests on)
- **Header-scoped tenancy.** The edge middleware derives the tenant from the subdomain and injects `x-tenant-id`. `get_request_tenant_id()` reads it (`request.headers`).
- **RLS is the boundary, not app code.** Every tenant-scoped table has RLS `ENABLE`d + `FORCE`d. Policies gate on `get_request_tenant_id()` and `is_request_tenant_admin()` / `is_request_tenant_member()`.
- **Anon reads only via SECURITY DEFINER RPCs** with column whitelists and an internal `tenant_id = get_request_tenant_id()` filter (e.g. `lookup_member`, `lookup_steward`). Anon has no direct SELECT on sensitive tables.
- **The anon key is public by design** — RLS, not secrecy, is the wall. That is exactly why RLS must be airtight.

The test harness reproduces this precisely: `set_config('request.headers', '{"x-tenant-id":"…"}', true)`, `set_config('request.jwt.claims', '{"sub":"…"}', true)`, and `SET LOCAL ROLE anon|authenticated`, inside a transaction that `ROLLBACK`s.

## 3 · Coverage matrix
| Area | Vector tested | Test |
|---|---|---|
| **Members** | admin-of-A cross-tenant SELECT/DELETE | `01_members_isolation.sql` |
| **Context** | missing header, invalid header | `02_negative_context.sql` |
| **Writes** | cross-tenant INSERT / UPDATE(takeover) / DELETE | `02_negative_context.sql` |
| **Credentials** | anon `lookup_member` cross-tenant; direct read denied | `member_verify_isolation_test.sql` |
| **Steward RPC** | `lookup_steward` tenant-scoped, public fields only | `steward_lookup_isolation_test.sql` |
| **Documents** | member reads only `published`; cross-tenant denied | `document_pipeline_isolation_test.sql` |
| **Grievances** | header selects tenant; cross-tenant denied | `grievance_tenant_isolation_test.sql` |

**Still to add** (extend the framework, same pattern): dedicated cross-tenant tests for `grievance_cases` assignments, `documents` storage-object access (Supabase Storage RLS, not just row RLS), and a full sweep asserting `tenant_id`-scoping on `public_roster`, `public_stats`, and `workplace_intelligence`. `get_public_site` / `resolve_site_tenant` are **intentionally public** (published site content) and are not isolation targets.

## 4 · ⚠ FINDING — cross-tenant gap in the 0008 admin read/write policies
Reading migration `0008` directly (confirmed: zero `RESTRICTIVE` policies exist anywhere, and no later migration re-tightens these):

- `members_admin_read`, `members_admin_update` (USING), `members_admin_delete`, `verifications_admin_read`, `dues_admin_read`, `audit_log_admin_read` all gate on **`USING (public.is_request_tenant_admin())` with no row-level `tenant_id = public.get_request_tenant_id()`**.
- `is_request_tenant_admin()` = `is_tenant_admin(get_request_tenant_id(), auth.uid())` — a **per-request boolean**, independent of the row.

**Consequence:** an authenticated admin of Tenant A (with header A) satisfies the USING for **every** row in these tables → can **read** all tenants' members/verifications/dues/audit logs, **delete** any tenant's members, and (via UPDATE, whose WITH CHECK only forces the *final* `tenant_id = A`) **reassign another tenant's member into their own tenant**. INSERT is safe (its WITH CHECK enforces the tenant).

**Severity: CRITICAL** — this is the exact breach the platform must prevent.

**Fix (one line per policy):** add the row filter to each USING —
```sql
-- e.g. members read
ALTER POLICY members_admin_read ON public.members
  USING (public.is_request_tenant_admin()
         AND tenant_id = public.get_request_tenant_id());
-- repeat for members_admin_update (USING), members_admin_delete,
-- verifications_admin_read, dues_admin_read, audit_log_admin_read.
```
Ship this as a corrective migration (proposed `0041_tenant_scope_admin_policies.sql`) **before** the live apply. `01_members_isolation.sql` and `02_negative_context.sql` are written to **fail today and pass once the fix lands** — that is the gate.

*(This finding was produced by static review; it is confirmed live the moment the suite runs — which is the point of building the suite.)*

## 5 · CI integration (make it permanent)
Add to the `steward-system` GitHub Actions:
```yaml
# .github/workflows/isolation.yml (sketch)
on: [pull_request, push]
jobs:
  tenant-isolation:
    runs-on: ubuntu-latest
    services: { postgres: { image: supabase/postgres, ... } }
    steps:
      - uses: actions/checkout@v4
      - run: supabase db reset            # apply 0001-0040 to the ephemeral DB
      - run: DATABASE_URL=$SCRATCH_URL ./tests/tenant-isolation/run_isolation_tests.sh
```
Gate on it: **a failing isolation test blocks the merge and the release.** Run it on every migration change, DB change, PR, and release tag.

## 6 · Rule for future developers (non-negotiable)
> **Every new tenant-scoped table ships with an isolation test in `tests/tenant-isolation/`, and RLS read/update/delete policies MUST include `tenant_id = public.get_request_tenant_id()` in the USING clause — an admin/role check alone is not isolation.**

The 0008 finding above is the cautionary tale: a role check without a row-tenant filter reads as "admin-only" but silently permits cross-tenant access. Copy `01_members_isolation.sql`, prove SELECT/INSERT/UPDATE/DELETE are A-only, and wire it into the runner before merging.
