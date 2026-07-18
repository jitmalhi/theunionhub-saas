# tests/tenant-isolation/ — the permanent security gate

Proves that **one tenant can never reach another tenant's data**. This is the highest-priority gate before any live database validation or accepting real member data. It is a *framework*, not a one-time test: it runs on migration changes, PRs, and releases.

## What it proves
A user (or a compromised session, a bad query, or an accidental code change) scoped to Tenant A cannot read, modify, or delete Tenant B's members, grievances, documents, credentials, verifications, dues, or audit logs — via **direct table access, SECURITY DEFINER RPCs, or missing/invalid tenant context.**

## How to run
```bash
# Point at a LOCAL, SCRATCH, or STAGING database with migrations 0001-0040 applied.
# NEVER production.
export DATABASE_URL='postgres://postgres:postgres@localhost:54322/postgres'   # e.g. supabase local
./run_isolation_tests.sh
```
Local DB from scratch:
```bash
npx --no-install supabase start
npx --no-install supabase db reset      # applies 0001-0040
DATABASE_URL='postgres://postgres:postgres@localhost:54322/postgres' ./run_isolation_tests.sh
```
Each test may also be pasted directly into the Supabase **SQL Editor** (its role can `SET ROLE`, which the tests require).

## Required environment
- `DATABASE_URL` — connection string to a **non-production** DB with `0001-0040` applied.
- Run as a role that can `SET LOCAL ROLE anon|authenticated` (the migration superuser / `postgres`, or the SQL Editor).
- `ISOLATION_ALLOW_PROD=1` — deliberately bypasses the prod-URL guard. Do not use.

## Expected results
- **PASS** → each file prints `PASS: …` and the runner exits `0`.
- **FAIL** → the runner prints the `FAIL:` message (which names the leak and the fix) and exits `1`.

> ⚠ **Known finding (see `docs/TENANT_ISOLATION_TESTING.md`):** against migration `0008` as written, `01_members_isolation.sql` and parts of `02_negative_context.sql` are **expected to FAIL** — the admin read/update/delete policies on `members` (and the read policies on `verifications`/`dues_collections`/`audit_log`) lack a `tenant_id = get_request_tenant_id()` row filter, allowing an authenticated admin of one tenant to reach another's rows. The failing assertions state the one-line fix. Once a corrective migration lands, these turn green — that is the gate.

## What's covered
| File | Area |
|---|---|
| `01_members_isolation.sql` | Members — authenticated-admin cross-tenant read/delete |
| `02_negative_context.sql` | Missing/invalid tenant context; cross-tenant INSERT/UPDATE/DELETE |
| `../../supabase/tests/member_verify_isolation_test.sql` | Credentials / `lookup_member` RPC (anon verify path) |
| `../../supabase/tests/steward_lookup_isolation_test.sql` | Steward RPC (`lookup_steward`) |
| `../../supabase/tests/document_pipeline_isolation_test.sql` | Documents / extractions (verify gate) |
| `../../supabase/tests/grievance_tenant_isolation_test.sql` | Grievances |

## Adding a new tenant-scoped table
Every new tenant-scoped table gets an isolation test **before it ships**. Copy the skeleton from `01_members_isolation.sql`: create Tenant A + Tenant B, insert a row in each, set the request context (`request.headers` x-tenant-id + `request.jwt.claims` sub + `SET LOCAL ROLE`), then assert the A-scoped caller sees/modifies **only** A's row and **zero** of B's — for SELECT, INSERT, UPDATE, and DELETE. See `docs/TENANT_ISOLATION_TESTING.md`.
