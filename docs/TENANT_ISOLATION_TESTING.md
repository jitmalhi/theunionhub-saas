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
Setup/cleanup: `00_fixtures.sql` provides `iso_test.make_pair()` (Tenant A + B, one admin each); the runner sets it up first and drops the `iso_test` schema after.

| Area | Vector tested | Test |
|---|---|---|
| **Members** | admin-of-A cross-tenant SELECT/DELETE | `01_members_isolation.sql` |
| **Context** | missing header, invalid header | `02_negative_context.sql` |
| **Writes** | cross-tenant INSERT / UPDATE(takeover) / DELETE | `02_negative_context.sql` |
| **Grievances / cases** | admin-of-A cross-tenant read + insert into B's `grievance_cases` | `03_grievance_isolation.sql` |
| **RPC (all DEFINER)** | every DEFINER fn pins `search_path`; `lookup_member` tenant-scoped | `04_rpc_inventory.sql` |
| **Credentials** | anon `lookup_member` cross-tenant; direct read denied | `member_verify_isolation_test.sql` |
| **Steward RPC** | `lookup_steward` tenant-scoped, public fields only | `steward_lookup_isolation_test.sql` |
| **Documents (rows)** | member reads only `published`; cross-tenant denied | `document_pipeline_isolation_test.sql` |
| **Grievances (RLS)** | header selects tenant; cross-tenant denied | `grievance_tenant_isolation_test.sql` |

### RPC inventory (SECURITY DEFINER surface)
DEFINER functions run as owner and bypass RLS internally, so each must (a) pin `search_path` — enforced generically for ALL of them by `04_rpc_inventory.sql` — and (b) enforce tenant context where it returns tenant data:

| Function | Tenant enforcement |
|---|---|
| `lookup_member`, `lookup_steward` | read `get_request_tenant_id()`, filter server-side; column-whitelisted | 
| `record_verification`, `check_already_collected`, `mark_member_paid` | explicit `tenant_id = get_request_tenant_id()` in WHERE |
| `is_tenant_admin`, `add_tenant_admin`, `remove_tenant_admin`, `update_tenant_settings` | derive tenant from header + `auth.uid()`; admin-gated |
| `public_roster`, `public_stats`, `workplace_intelligence` | tenant-scoped by header — **add explicit cross-tenant assertions next** |
| `get_public_site`, `resolve_site_tenant` | **intentionally public** (published site content) — not isolation targets |
| `export_site` | admin-gated (content ownership) |

**Storage caveat (honest):** the SQL suite proves **row/metadata** isolation for `documents` / `document_extractions`. Actual object bytes, downloads, and **signed URLs** live in the Supabase **Storage** layer, which SQL RLS tests cannot exercise — that requires a separate integration test (per-tenant bucket/prefix + Storage policies + attempted unauthorized signed-URL fetch). Tracked as a Phase-6 follow-up; do not treat row-isolation as proof of object-isolation.

**Still to add** (same pattern): explicit cross-tenant assertions on `public_roster` / `public_stats` / `workplace_intelligence`; grievance `assigned_to` + `grievance_history` cross-tenant; and the Storage-object integration test above.

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
