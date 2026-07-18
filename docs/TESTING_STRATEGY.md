# TESTING STRATEGY — The Union Hub

**Phase 12** · 2026-07-16 · Branch `release/v0.1-production-hardening`
**Goal:** a developer can validate the platform with confidence, and tenant-safety is *proven*, not assumed. Optimized for trust and correctness, not coverage vanity.

> Fits the actual stack: no-build static HTML + ES modules, `@vercel/edge` middleware, Vercel serverless (`api/`), Supabase (Postgres + RLS + Auth). The heaviest, most important tests live **in the database**, because that's where tenant safety is enforced.

---

## 1 · Test layers (what runs where)

| Layer | What it proves | Tooling | Runs in |
|---|---|---|---|
| **Database / RLS** (primary) | Tenant isolation, privacy, confidentiality, integrity constraints, triggers | plpgsql `ASSERT` + `ROLLBACK` scripts (the existing pattern) | Supabase SQL Editor + CI scratch DB |
| **RPC / function** | DEFINER RPCs return only whitelisted columns, tenant-scoped | SQL test scripts calling `lookup_member`, `lookup_steward`, `get_public_site`, etc. | same |
| **API / serverless** | `api/*` behave (health, verify path, writers, site render) | HTTP smoke tests (curl/node) against a preview/staging URL | CI + staging |
| **Auth** | Magic-link issue/verify, session handling, dev-bypass gating | Scripted OTP flow against staging Supabase | staging |
| **Workflow** | Grievance lifecycle transitions, deadline computation, notifications | SQL + API scenario tests | CI + staging |
| **Middleware / routing** | Subdomain→tenant, apex rewrite, fail-open degrades to apex not to a tenant | HTTP tests against preview deploys | CI (preview) |

**Principle:** the DB layer is the source of truth for security. An RLS test that never runs is not a test — see the CRITICAL item in `PRODUCTION_READINESS_STATUS.md`.

## 2 · Database & RLS tests

Reuse and extend the established self-contained pattern (each script sets a role, asserts, and ends in `ROLLBACK` so it leaves no data):
- Existing: `supabase/tests/{member_verify,steward_lookup,document_pipeline,grievance_tenant}_isolation_test.sql`.
- Phase 3 formalizes these into `tests/tenant-isolation/` as the permanent suite.
- Each test: `SET ROLE anon|authenticated`, set the tenant header context, run the query/RPC, `ASSERT` the expected allow/deny, `RESET ROLE`, `ROLLBACK`.

**Adopt pgTAP** (optional, recommended) for richer assertions and CI-friendly TAP output — but the plpgsql `ASSERT` scripts are sufficient for v0.1 and already proven.

## 3 · Critical tests (the gate)

These are non-negotiable before customer #1. Each maps to a blocker in the readiness status.

1. **Tenant isolation (B2).** User of Tenant A cannot read/write Tenant B's members, grievances, documents, credentials, audit logs — via direct table query, via every DEFINER RPC, and via the anon verify path. *(Phase 3 suite.)*
2. **Member privacy.** Anon cannot enumerate `members`; `lookup_member` returns only whitelisted card columns; a member reads only their own record.
3. **Grievance confidentiality.** A member sees only their own `grievance_cases`; a steward only their coverage; admins per tenant; `grievance_history` is unreadable cross-tenant and unmodifiable (append-only trigger).
4. **Document access control.** `documents` / `site_documents.visibility` gating holds at BOTH the row (RLS) and the object (Storage policy) layer — no unauthorized download URL works. *(Depends on Phase 6 storage review.)*
5. **Voting integrity.** *Not yet applicable — no voting tables exist.* When voting is built (v1.5), this becomes a first-class critical test: ballot secrecy, one-member-one-vote, append-only + independently verifiable tally. **Documented now so it is never skipped later.**

## 4 · CI (the missing foundation)

Add GitHub Actions on the `steward-system` repo:
- **On every push/PR:** `node --check` across `api/` + `lib/` + `js/`; JSON validity for `vercel.json`/`package.json`.
- **On every push/PR:** spin an ephemeral Postgres (or `supabase start` locally / a scratch Supabase project), apply migrations `0001–0040`, run the entire `tests/tenant-isolation/` suite; **fail the build on any assertion failure.**
- **On merge to `main`:** run API smoke tests against the resulting preview deploy before promoting.

This turns "tests exist" into "tests gate releases" — the difference between 3/10 and 7/10 on the testing dimension.

## 5 · Local developer workflow
- `npx --no-install supabase start` (local stack) → apply migrations → run test scripts, OR use a scratch Supabase project + SQL Editor for the isolation suites (the SQL Editor role can `SET ROLE`, which the tests require).
- API: run against `vercel dev` or a preview URL; never against production.
- **Never** run tests, seeds, or experiments against the production project.

## 6 · v0.1 exit criteria (testing)
- All Phase-3 isolation tests **green live** (recorded in `TENANT_SECURITY_VALIDATION.md`).
- CI running `node --check` + the SQL suite on a scratch DB, gating merges.
- API smoke suite passing against staging.
- Voting-integrity test **specified** (built when voting is).
