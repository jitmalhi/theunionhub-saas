# PRODUCTION READINESS STATUS — The Union Hub

**Phase 1 · Production Baseline Assessment** · Prepared 2026-07-16 · Branch `release/v0.1-production-hardening`
**Companion to** `ARCHITECTURE-REVIEW.md` (the full engineering review). This document is the *current-state snapshot* and the *order of work*; the review is the *reference*.

> **Overall production readiness: ~4/10 — NOT production ready.** The architecture is sound (~8/10). The gap is operational execution, not design. Everything below is a known, finite list.

---

## 1 · Current state (verified against code + live probe)

### Migration state
- **Repository:** migrations `0001–0040` present (39 files; `0031` intentionally reserved/absent).
- **Live database:** at **`0021`** (confirmed live: `/api/health` returns `migration_version:"0021"`, `region:"ca"`, `service_role_configured:true`).
- **Delta:** `0022–0040` exist and are syntax-reviewed, **but have never been applied or proven on the live DB.** 19 migrations of intended architecture are dormant.

### Supabase schema state (repo intent vs. live)
- **Repo intent:** 33 tables, 70 indexes, 67 FK references, 28 RLS-enabled tables, ~50 functions/RPCs.
- **Live reality:** only the `0001–0021` subset exists (tenants, members, stewards, grievances[legacy], knowledge_entries, member_interactions, audit_log, verifications, tenant_admins, dues, workplace_intelligence). **The entire grievance-case, deadline, precedent, document-pipeline, and hosted-site schema (`0022–0040`) is not live.**

### Application state
- **Two codebases, not merged:**
  - `steward-system` — **live**. No-build static HTML + ES modules, `@vercel/edge` middleware (subdomain→`x-tenant-id`), Vercel serverless (`api/`), Supabase. Passwordless magic-link.
  - `grievance-system` — **not merged**. React/Vite SPA + 2 Supabase Edge Functions (Deno/TS, AI). Its DB layer is migrations `0022–0030`, folded into `steward-system` numbering but unapplied.

### Deployed functionality (live at `theunionhub.ca`)
- ✅ DNS + Vercel + HTTPS live; `.ca` canonical, `www`→apex redirect correct.
- ✅ Marketing site (real homepage + `card`/`verify`/`brandbook` demos + 8 legal pages) served from `app/`.
- ✅ Backend connected: `/api/health` 200, Supabase reachable, service-role configured, region `ca`.
- ⚠️ App tier (admin, tenant card/verify against real data, DFR/interaction writers) depends on schema that is **only at 0021** — so grievance/site/pipeline features are **not live**.
- ❌ `.com`→`.ca` redirect (GoDaddy) not done; wildcard tenant subdomains not set up (Vercel Pro).

### Missing migrations / broken dependencies
- **Missing (unapplied):** `0022–0040`.
- **Dependency chain to respect:** `0040` (document pipeline) depends on `0022` (`is_request_tenant_member`); `0033` (lookup_member+member_number) depends on `0032`; site RPCs (`0038/0039`) depend on `0036/0037`. Apply strictly in order.
- **No known broken code dependencies** — `node --check` passes on edited JS; `vercel.json`/`package.json` valid. The risk is *schema drift at apply time*, not code breakage.

### Duplicate / competing systems
1. **Grievance model duplication:** `grievances` (0017, legacy, live) vs `grievance_cases` (0024, richer, unapplied). **Two sources of truth.** → Phase 4.
2. **Front-end duplication:** static `steward-system` vs React `grievance-system`. → Phase 5.
3. **Knowledge stores (justifiable, needs documented boundary):** `knowledge_entries` / `grievance_precedents` / `document_extractions`.

### Security risks (summary — full treatment in Phase 3 & 6)
- **[CRITICAL]** Tenant isolation is proven only in **unrun** tests. Cross-tenant leakage is the existential risk.
- **[CRITICAL]** No live backups (free tier) — data loss unrecoverable.
- **[HIGH]** Middleware tenant lookup fail-open — must degrade to apex, never to a tenant.
- **[HIGH]** No rate limiting on anon RPCs / magic-link issuance.
- **[HIGH]** Hardcoded Supabase project in `domains.js`/`live.js` (clone hazard).
- **[MEDIUM]** Storage/object RLS unverified; no data-retention/deletion tooling; binary admin/not-admin authorization (no role tiers).

---

## 2 · Blocking issues (must clear before the first paying customer)

| # | Blocker | Phase | Why it blocks |
|---|---|---|---|
| B1 | `0022–0040` unapplied / unproven live | 2 | Product capability ≠ live capability |
| B2 | Tenant isolation not proven live | 3 | A leak between two locals is fatal to trust |
| B3 | No backups / tested restore | 7 | One bad day = unrecoverable member/grievance data |
| B4 | Grievance model duplication unresolved | 4 | Ambiguous source of truth for the core workflow |
| B5 | No rate limiting / abuse controls | 6 | Enumeration + cost + DoS on anon endpoints |
| B6 | No data-retention/deletion tooling | 8 | PIPEDA / Law 25 non-compliance with real PII |
| B7 | No monitoring / incident response | 7 | Blind to outages and breaches |

## 3 · Non-blocking issues (fix soon, not gating customer #1)

| # | Issue | Phase |
|---|---|---|
| N1 | React SPA not merged into the primary stack | 5 |
| N2 | Role tiers (Executive/Officer/Steward/Member/Auditor) | 6 |
| N3 | Third-party pen test | 6 (gate before *scale*, strongly advised before #1) |
| N4 | `.com`→`.ca` redirect, wildcard subdomains | ops |
| N5 | CRLF/formatter/CI hygiene | ops |
| N6 | Naming drift; knowledge-store boundary docs | 4 |
| N7 | Performance work (materialized views, partitioning) — not needed at first-customer scale | 9 |

## 4 · Recommended order of work (this branch = v0.1)

**Author-now track (no live DB required) — do these first, in this order:**
1. **Phase 4 — Grievance architecture decision** (`GRIEVANCE_ARCHITECTURE_DECISION.md`). Unblocks B4 and the apply plan.
2. **Phase 5 — Application architecture decision** (`APPLICATION_ARCHITECTURE_DECISION.md`). Settles N1's direction.
3. **Phase 3 (author) — Isolation test suite** (`tests/tenant-isolation/`). The *proof harness* for B2.
4. **Phase 6 — Security model** (`SECURITY_MODEL.md`, incl. role tiers).
5. **Phase 8 — Privacy model** (`PRIVACY_MODEL.md`, incl. retention/deletion → B6).
6. **Phase 7 — Operations runbook** (`OPERATIONS_RUNBOOK.md`: monitoring, logging, backup/restore, DR, incident response → B3/B7).
7. **Phase 2 (author) — Migration audit + safe execution plan** (extends APPLY-RUNBOOK; per-migration purpose/risk).
8. **Phases 9/10/11** — performance, strategy, roadmap (refine from the review).

**Live-execution track (gated — driven session, you at the terminal, I verify each gate):**
9. **Phase 2 (execute)** — backup → apply `0022–0040` → verify → `DATABASE_VALIDATION_REPORT.md`.
10. **Phase 3 (execute)** — run the isolation suite live → `TENANT_SECURITY_VALIDATION.md`.
11. **Post-apply ops** — turn on Supabase Pro/PITR (B3), rate limiting (B5), monitoring (B7).

**Definition of done for v0.1:** B1–B7 cleared, isolation suite green live, DATABASE_VALIDATION and TENANT_SECURITY_VALIDATION reports signed off.

---

## 5 · Readiness scorecard (this phase)

| Dimension | Score /10 | Δ to green |
|---|---|---|
| Database (schema live vs intended) | 6 | Apply `0022–0040`, prove it |
| Security | 5 | Prove isolation live; rate limiting; roles |
| Testing | 3 | Suite exists but unrun; no CI |
| Deployment | 6 | Live; needs staging/CI, `.com` redirect |
| Monitoring | 2 | None beyond `/api/health` |
| Backup / DR | 2 | None; must add PITR + tested restore |
| Documentation | 8 | Strong and getting stronger this phase |
| Scalability | 7 | Over-provisioned for first-customer scale |
| Privacy compliance | 4 | Posture good; tooling/policy missing |
| **Overall** | **~4/10** | **Clear B1–B7** |

_Next: Phase 4 — the grievance architecture decision._
