# The Union Hub — Architecture Review & Knowledge Extraction

**Status:** permanent architectural reference · **Prepared:** 2026-07-16 · **Basis:** direct code audit of `steward-system` (live) + `grievance-system` (merging).
**Ground truth at time of writing:** 33 tables, 70 indexes, 67 FK references, 28 RLS-enabled tables, ~50 functions/RPCs, migrations `0001–0040`. **Live database is at `0021`; `0022–0040` are staged, syntax-reviewed, NOT applied. `grievance-system` (React SPA) is NOT yet merged. Zero paying customers.**

> Read this honestly: the *architecture* is strong for the stage; the *operational maturity* is early. Both statements are true and this document keeps them separate.

---

## 1 · Executive Architecture Review

**Overall shape.** Two systems converging into one:
- **`steward-system`** — the live multi-tenant SaaS. **No build step**: static HTML + ES modules served by Vercel, `@vercel/edge` middleware for subdomain→tenant routing, Vercel serverless functions (`api/`), Supabase (Postgres + RLS + Auth). Passwordless magic-link auth.
- **`grievance-system`** — a React/Vite SPA with 10 migrations + 2 Supabase Edge Functions (Deno/TS) for AI. Being folded into `steward-system` via migrations `0022–0030`.

**Tenancy model (the spine).** `lib/domains.js` is a host→config registry (region-aware, data-residency-ready). The edge middleware parses the subdomain → tenant slug → looks up the tenant → injects an `x-tenant-id` header. Every RLS policy calls `get_request_tenant_id()` off that header. Admin/member gates: `is_request_tenant_admin()` (0008) and `is_request_tenant_member()` (0022). Anonymous reads go through **SECURITY DEFINER RPCs** (`lookup_member`, `lookup_steward`) that return whitelisted columns only.

| Area | Rating | Why |
|---|---|---|
| Overall architecture | **8/10** | Clean separation (edge routing / RLS data plane / thin serverless). No-build model is a genuine strength for a solo team. −2: two codebases not yet unified; live/staged drift. |
| Design strengths | **8/10** | RLS-first isolation, DEFINER RPCs for anon, no-build simplicity, region-aware registry, append-only history with mutation-prevention triggers. |
| Weaknesses | **5/10** | Middleware tenant lookup is fail-open on error; no rate limiting; two stacks; live DB 19 migrations behind the repo. |
| Technical debt | **5/10** | Unmerged React SPA, unapplied `0022–0040`, tests written but never executed live, hardcoded Supabase project in `domains.js`. |
| Scalability | **7/10** | Postgres + RLS + edge scales far for this domain (unions are ≤ hundreds of thousands, not millions). Indexing is already thoughtful (70 indexes). |
| Security | **7/10** | Strong model (RLS, DEFINER RPCs, passwordless, CSP headers, no client secrets). −3 until isolation tests run **live** and a pen test exists. |
| Maintainability | **7/10** | Small, readable modules; consistent `lib/admin-*` pattern; heavy inline documentation in migrations. −: no automated tests in CI. |
| Extensibility | **8/10** | New tenant = DNS + row, no redeploy. New module = migration + `lib/admin-*` + template page. Very additive. |
| Multi-tenant design | **9/10** | Header-driven RLS with DEFINER-RPC escape hatches is the correct pattern; 28 tables RLS-enabled; 67 `tenant_id` scopings. Best part of the system. |
| Member identity | **8/10** | Passwordless magic-link, per-tenant `member_number` (auto-assign trigger + counters), QR verify via whitelisted DEFINER RPC. −: no credential revocation/rotation story yet. |
| Steward workflow | **7/10** | `stewards`, `steward_coverage`, role guards (admin-only role changes), `lookup_steward` PII lockdown. −: assignment logic is thin. |
| Grievance management | **6/10** | Rich schema (cases, deadlines+rules, history, notifications, precedents) — but it lives in the **unapplied/unmerged** tier, so it's design-complete, not operational. |
| Collective-agreement data | **6/10** | `cba_articles` + `grievance_precedents` + the `0040` document pipeline (verify gate) are a strong foundation; extraction/search is schema-first, UI-thin. |
| Database design | **8/10** | Normalized, FK-rich (67), append-only audit, trigger-enforced integrity. −: a few naming drifts (see §2). |
| Folder structure | **8/10** | `api/ lib/ app/ tenants/_template/ supabase/{migrations,tests,snippets}` is clear. `lib/admin-*` convention scales. |
| Coding standards | **7/10** | Consistent ESM, `esc()` XSS helper, shared `reserved-slugs`. −: no linter/formatter in CI; CRLF drift. |
| Long-term sustainability | **6/10** | Architecture will last; **the risk is people, not code** — solo maintainer, bus factor 1, no CI/monitoring. |

**Headline:** an **8/10 architecture at ~4/10 operational readiness.** The design decisions are the kind you'd want to keep; the gap to production is execution (merge, apply, test live, instrument), not redesign.

---

## 2 · Database Review

**Entity map (33 tables), by role:**

**Core platform infrastructure**
- `tenants` — the tenant root; slug (CHECK-constrained, shared `reserved-slugs`), branding, dues cycle, logo. Everything hangs off `tenant_id`.
- `tenant_admins` — who administers a tenant (0006/0008). Drives `is_request_tenant_admin()`.
- `tenant_hostnames` + `site_settings` (0036) — custom hostnames + the Tier-1 hosted-website config (`resolve_site_tenant`, `site_is_published`).
- `audit_log` (0004) — append-only platform audit.
- `verifications` — QR verify events (`record_verification`).
- `member_number_counters` (0035) — per-tenant sequence source for `assign_member_number`.

**Union-specific workflow**
- `members` — the roster; extended (0023) with status, contact, `member_number` (0032). `member_history` is append-only (mutation-prevention trigger).
- `stewards` + `steward_coverage` + `steward_analytics` (0013/0022) — representatives, their coverage areas, scan analytics.
- `grievances` (0017, legacy) and `grievance_cases` (0024, the merged model) — **redundancy to reconcile** (see below).
- `grievance_deadlines` + `grievance_deadline_rules` (0026) — SLA clock, auto-calculated via `set_grievance_deadline` / `calculate_next_deadline` triggers.
- `grievance_history` — append-only case trail. `grievance_notifications` (0028) — deadline/escalation alerts.
- `grievance_precedents` + `cba_articles` (0025) — collective-agreement knowledge + precedent linking (`validate_precedent_integrity`).
- `documents` (0029 document vault) + `source_documents` + `document_extractions` (0040 pipeline, with the **published-only verify gate** for members).
- `knowledge_entries` (0018) + `member_interactions` (0020) + `workplace_intelligence` (0021) — the DFR/knowledge layer.
- `ai_generations` (0030) — AI output audit (append-only, mutation-prevention trigger).
- `dues_collections` (0010) — dues cycle records.
- `site_*` (0037): `site_alerts, site_posts, site_officers, site_stewards, site_meetings, site_documents` — the hosted-website content, published-gated.

**Findings**

*Redundant / to reconcile*
- **`grievances` (0017) vs `grievance_cases` (0024).** Two grievance models coexist because the merge isn't applied. **Decision needed:** migrate `grievances` → `grievance_cases` and deprecate the former, or formally scope each. This is the #1 schema debt.
- `knowledge_entries` (0018) vs `grievance_precedents` (0025) vs `document_extractions` (0040) — three "knowledge" stores. Justifiable (freeform notes / CBA precedent / extracted doc facts) but needs a documented boundary or they'll drift into overlap.
- `site_stewards`/`site_officers` (public site) vs `stewards`/`tenant_admins` (app) — intentional (public projection vs source of truth), but document it so no one "dedupes" them wrongly.

*Indexes (70 present — good)*
- Verify hot paths carry indexes. **Add/confirm** composite `(tenant_id, status)` on `members` (roster filters), `(tenant_id, deadline_at)` on `grievance_deadlines` (the notification sweep), `(tenant_id, created_at)` on `audit_log`/`ai_generations` (time-range reads), and a GIN/trigram index on `cba_articles` body once article search ships.

*Normalization / integrity*
- Append-only tables (`*_history`, `ai_generations`) enforce immutability via triggers — excellent. Keep that pattern for anything auditable (voting!).
- FK coverage is strong (67). Confirm **every** `tenant_id` is a real FK to `tenants(id)` with `ON DELETE` policy chosen deliberately (cascade vs restrict) — tenant deletion semantics must be explicit before production.

*Naming consistency*
- Minor drift: `grievance_deadline_rules` vs `grievance_deadlines`; `member_history` vs `grievance_history` (fine) vs `audit_log` (singular). Standardize on plural table names in future migrations; don't rewrite history.

*Partitioning (future)*
- Not needed at current scale. First candidates when they grow: `audit_log`, `verifications`, `member_interactions`, `ai_generations` — high-insert, time-series, read-by-range. Range-partition by month at ~50k+ members (see §5).

---

## 3 · Security Review

**Model (strong).** RLS-first, header-scoped tenancy, DEFINER RPCs for anon reads, passwordless auth (no password store to breach), service-role key server-only, CSP/HSTS/X-Frame headers in `vercel.json`, `esc()` for output encoding.

**Concerns, ranked**

1. **[CRITICAL] Isolation is proven only in *unrun* tests.** The three isolation suites (`member_verify`, `steward_lookup`, `document_pipeline`) plus `grievance_tenant_isolation` exist but have **never executed against the live DB** (it's at 0021). Cross-tenant leakage is the existential risk for a multi-tenant union platform. **Gate: these must pass live before customer #1.**
2. **[CRITICAL] Middleware fail-open.** Tenant lookup "fails open on errors" for availability. Confirm that a lookup failure can never resolve to the *wrong* tenant or an over-privileged context — fail-open must degrade to *marketing/apex*, never to a tenant's data.
3. **[HIGH] Hardcoded Supabase project in `domains.js`/`live.js`.** Fine for one deployment; a landmine for clones (see AIXPG). Move to env for all regions; keep only non-secret anon values baked.
4. **[HIGH] No rate limiting / abuse controls** on `lookup_member`, `lookup_steward`, `record_verification`, or magic-link issuance. Anon RPCs + OTP endpoints need throttling (edge or Supabase) before public traffic.
5. **[HIGH] Voting integrity is unbuilt.** No voting tables yet. When built, it must be append-only, cryptographically verifiable, and separable from member identity (ballot secrecy). Do not bolt this onto existing patterns without a dedicated design.
6. **[MEDIUM] Storage policies.** Document vault (`documents`, `site_documents.visibility`) needs Supabase Storage RLS reviewed end-to-end (signed URLs, per-tenant buckets/prefixes, member-vs-public gating). Schema gates content; confirm the *object store* gates the bytes.
7. **[MEDIUM] Secrets & retention.** `.env.local` handling is correct (gitignored, verified). Missing: a written **data-retention policy** (grievance records, audit logs, AI generations) and deletion/export tooling for PIPEDA/Law 25 rights.
8. **[MEDIUM] Audit completeness.** `audit_log` exists but confirm it captures admin actions comprehensively (role changes, member edits, document access) — auditability is a *product* feature for unions, not just ops.

**Enterprise-grade recommendations:** run isolation suites live (gate); add rate limiting + OTP throttling; parameterize backend config; commission a third-party pen test before any customer with real grievance data; write retention + deletion tooling; formalize the incident-response runbook.

**Special attention**
- **Member PII / grievance confidentiality:** grievances are legally sensitive. Members must read only their own; stewards only their coverage; executives per role. The `is_request_tenant_member`/`is_request_tenant_admin` split is right — verify the *middle* tier (steward scope) is enforced in RLS, not just app code.
- **CBA documents:** the CBA itself is often public (member's own website/employer portal) — but *drafts, bargaining notes, and precedent analysis* are not. The `document_extractions` verify gate (published-only) is the correct seam; keep bargaining material out of member-readable tiers.
- **Voting & audit trails:** see #5; append-only + independent verifiability are non-negotiable.

---

## 4 · Union Operations Engine Review

**Member Identity.** Passwordless magic-link (Supabase OTP, `type:'magiclink'`, member-facing name "secure sign-in link"). Digital card (`tenants/_template/card.html`) renders a QR; the rep's verify screen calls `lookup_member` (SECURITY DEFINER, whitelisted columns, tenant-scoped) → Verified / Not valid / Not found. `member_number` is per-tenant, auto-assigned. **Security model is sound**; add credential revocation + a re-issue flow.

**Steward Operations.** `stewards` + `steward_coverage`; role changes are admin-only (`enforce_steward_role_admin_only`); `claim_representative` self-service; `lookup_steward` exposes only public card fields to anon. **Gap:** assignment/matching (which steward owns which member/grievance) is thin — build explicit coverage→case routing.

**Grievance Management (design-complete, not live).** Lifecycle in `grievance_cases` with status, `grievance_history` (immutable trail), `grievance_deadlines` + `grievance_deadline_rules` (auto-computed SLA clock via triggers), `grievance_notifications` (deadline/escalation), `grievance_precedents` (link to `cba_articles`). Escalation is rule-driven. **This is the strongest *latent* asset** — it's the "institutional knowledge" wedge from the strategy work. Priority: apply, merge the React UI, run the deadline sweep as a real background job (§5).

**Collective-Agreement Knowledge.** `cba_articles` (clause storage) + `grievance_precedents` + the `0040` pipeline (`source_documents` → `document_extractions` with published-only verify gate). Search is not yet built. **Future AI:** RAG over `cba_articles` ("ask the agreement"), precedent suggestion on new grievances, and extraction QA — all gated behind the verify step so AI only surfaces *human-approved* facts. The `ai_generations` audit table is the right place to log every model output.

**Integration guidance for future modules:** one migration (RLS-enabled, tenant-scoped, FK to `tenants`, append-only history if auditable) + one `lib/admin-<module>.js` + one `tenants/_template/<page>.html`. Reuse `get_request_tenant_id()` / `is_request_tenant_*()`; expose anon reads only via DEFINER RPCs with column whitelists. Never widen RLS to ship faster.

---

## 5 · Performance Review (1k → 250k members)

- **1,000 members:** no concerns. Current design is over-provisioned for this. Ship it.
- **10,000:** watch the **deadline-notification sweep** (`run_deadline_notifications`) — must be an indexed, scheduled job, not an on-request scan. Add `(tenant_id, status)` on `members`, `(tenant_id, deadline_at)` on `grievance_deadlines`.
- **50,000:** introduce **materialized views** for admin dashboards/reporting (`admin-stats`, `admin-intelligence`) refreshed on a schedule; add **trigram/GIN search** on `cba_articles` and members; move analytics reads (`steward_analytics`, `verifications`) off the transactional path.
- **250,000:** **partition** high-insert time-series tables (`audit_log`, `verifications`, `member_interactions`, `ai_generations`) by month; consider a read replica for reporting; move heavy analytics to a separate OLAP store; make the deadline engine and notifications fully **event-driven** (queue + worker) rather than cron-scan.

**Cross-cutting:** add edge caching for `get_public_site` (published sites are cache-friendly); background jobs for notifications, extraction, and AI (never in the request path); a real search index once article/precedent search ships. **When each becomes necessary:** materialized views ~50k; search indexing when CBA search ships (any scale); event-driven processing ~50–250k or when notification volume outgrows a cron scan; analytics DB at 250k or first serious multi-tenant reporting demand.

---

## 6 · Future Union Modules (priority order)

| # | Module | Member value | Leadership value | Complexity | Depends on | Effort |
|---|---|---|---|---|---|---|
| 1 | **Grievance Management** (finish/ship) | High | Very high | Med | 0022–0028 applied, React merge | M (built; needs apply+UI+jobs) |
| 2 | **Digital Member Credential** (harden) | High | Med | Low | live | S (revocation/reissue) |
| 3 | **CBA Intelligence + search** | High | High | Med-High | 0025/0040, search index | M-L |
| 4 | **Member Portal** (self-serve status/history) | Very high | Med | Med | member auth (live) | M |
| 5 | **Steward Portal** (caseload, coverage) | Med | High | Med | grievance, coverage | M |
| 6 | **Workplace Issue Reporting** (intake → grievance) | High | High | Low-Med | grievance | S-M |
| 7 | **Member Communications** (targeted, roster-aware) | High | High | Med | roster, consent | M |
| 8 | **Document Management** (harden vault) | Med | High | Med | 0029, storage RLS | M |
| 9 | **Secure Voting / Ratification** | High | Very high | **High** | new integrity design | L |
| 10 | **Strike Authorization Voting** | High | Very high | High | voting core | M (on voting) |
| 11 | **Meeting Management** (agendas, minutes, quorum) | Med | High | Med | — | M |
| 12 | **Elections** (officer elections) | Med | High | High | voting core | M-L |
| 13 | **Bargaining Support** (proposals, redlines) | Low(member) | Very high | High | CBA intelligence | L |
| 14 | **Training Tracking** (certs, stewards' training) | Med | Med | Low | — | S |
| 15 | **Dues Integration** (payments/reconciliation) | Med | High | High | `dues_collections`, PCI/partner | L |
| 16 | **AI Union Assistant** (RAG over CBA + precedent) | High | High | Med-High | CBA intelligence, `ai_generations` | M-L |

**Additional recommended:** Benefits/PTO reference, Shop-steward mobile quick-verify, Anonymous tip line (whistleblower-safe), Convention/delegate management, Grievance analytics (win rates by article/employer — a genuine differentiator).

**Sequencing logic:** finish what's built (1–3), deepen the two portals (4–5), then the high-integrity modules (voting/elections) only once the security bar (§3) is met.

---

## 7 · Union Market Expansion

**Constant across all sectors** (the reusable ~70%): multi-tenant core, member identity + card + verify, roster/dues, steward model, grievance lifecycle, CBA storage, audit, hosted site.

| Sector | What changes / additional modules | Opportunity |
|---|---|---|
| **Public sector** | Multi-employer, complex classifications, FOI/records rules; strong grievance + arbitration tracking | Large locals, stable, compliance-driven — ideal beachhead |
| **Healthcare** | Shift/credential/licensure tracking, high member counts, safety reporting | High grievance volume; safety-issue reporting is a wedge |
| **Municipal** | Multiple bargaining units per employer, council/political calendars | Mid-size, relationship-driven |
| **Construction/Trades** | Hiring hall, dispatch, apprenticeship/hours, transient membership | Dispatch + hours tracking are net-new, high-value |
| **Manufacturing** | Plant-level units, seniority/bidding, layoff-recall | Seniority + recall modules add-on |
| **Transportation** | Runs/rosters, safety/discipline, DOT-style rules | Discipline tracking + fatigue/safety |
| **Education** | Academic calendars, tenure/seniority, multi-campus | Seniority + workload complaints |
| **Energy** | Safety-critical, remote sites, certifications | Safety + certification-heavy |

**Play:** win one sector deeply (public sector or healthcare — highest grievance volume, most acute knowledge-continuity pain), then template the sector-specific add-ons. The core doesn't change; the *modules* do.

---

## 8 · Technical Debt Register

| Pri | Item | Business risk | Technical risk | Recommendation | Effort |
|---|---|---|---|---|---|
| **Critical** | `0022–0040` unapplied; live DB at `0021` | Product promise ≠ live capability | Migration drift, apply-time surprises | Run APPLY-RUNBOOK with backup + isolation gates | M |
| **Critical** | Isolation suites never run live | Cross-tenant data leak = fatal | Unproven RLS | Execute all 4 suites live; make a CI gate | S |
| **Critical** | `grievances` vs `grievance_cases` duplication | Confused source of truth | Divergent data | Pick one, migrate, deprecate other | M |
| **High** | Two codebases (static + React SPA) unmerged | Slower delivery, split effort | Divergence | Complete the merge per MERGE-PLAN | L |
| **High** | Hardcoded Supabase project in code | Clone leaks (AIXPG) | Wrong-DB writes | Env-parameterize all backend config | S |
| **High** | No rate limiting / OTP throttling | Abuse, cost, enumeration | DoS/enumeration | Edge throttle on anon RPCs + magic-link | S-M |
| **High** | No CI/CD, no automated test run | Regressions ship silently | Quality erosion | GitHub Actions: node --check, run SQL tests on a scratch DB | M |
| **Medium** | No monitoring/alerting/error tracking | Blind to outages | MTTR high | Add uptime + error tracking + log drain | S-M |
| **Medium** | Backups (free tier = none) | Data loss | Unrecoverable | Supabase Pro PITR before real data | S |
| **Medium** | Storage/object RLS unverified | Doc leak | Bytes vs rows gap | Audit Storage policies end-to-end | S |
| **Medium** | Data retention/deletion tooling absent | PIPEDA/Law 25 non-compliance | Legal | Build export + delete; write retention policy | M |
| **Low** | CRLF/LF drift; no formatter | Noise | Diff churn | `.gitattributes` + prettier (scoped) | S |
| **Low** | Naming drift (singular/plural) | Minor confusion | — | Standardize going forward | S |

---

## 9 · Product Roadmap → v2.0

**v0.2 — Make what's built real.** *Objectives:* production-grade single-tenant-per-local live. *Features:* apply `0022–0040`; isolation suites green live; grievance UI merged; deadline notifications as a scheduled job; credential revocation; rate limiting. *Dependencies:* Supabase Pro, APPLY-RUNBOOK. *Risks:* migration apply, RLS gaps.

**v0.3 — First customer readiness.** Member Portal (self-serve status/history); Steward Portal (caseload/coverage); Workplace Issue Reporting → grievance intake; monitoring/logging/backups; retention + deletion tooling; pen test. *Risk:* scope creep — hold the line to one design-partner's needs.

**v0.5 — CBA Intelligence.** Article/clause search (trigram/GIN); precedent suggestion; the `0040` pipeline in production with the verify gate; **AI "ask the agreement"** (RAG, human-verified only). *Dependency:* search index, `ai_generations` audit.

**v1.0 — The operating platform.** Member Communications; Document Management hardened; Meeting Management; grievance analytics (win-rates); multi-unit support; wildcard tenant subdomains at scale. Multi-tenant reporting via materialized views.

**v1.5 — High-integrity governance.** Secure Voting / Ratification (append-only, verifiable, ballot-secret); Strike Authorization; Elections. Only after the §3 security bar is met and audited.

**v2.0 — The category leader.** Bargaining Support; Dues Integration; sector module packs (dispatch/hours, seniority/recall, safety); federation-level tenancy (locals→districts→nationals); pooled anonymized precedent library as a moat.

---

## 10 · Production Readiness

| Dimension | Score /10 | Note |
|---|---|---|
| Database | 6 | Well-designed; **live schema 19 migrations behind**; deletion semantics undecided |
| Security | 5 | Strong model, **unproven live**; no rate limiting/pen test |
| Testing | 3 | Suites exist, **never run live**; no CI |
| Deployment | 6 | Vercel live, `.ca` canonical, healthy `/api/health`; no staging/CI pipeline |
| Monitoring | 2 | None beyond `/api/health` |
| Logging | 3 | App-level only; no aggregation/alerting |
| Backup | 2 | Free tier = none; **must fix before real data** |
| Disaster recovery | 2 | No tested restore path |
| Documentation | 8 | Unusually strong (this doc, runbooks, MERGE/APPLY plans, inline SQL) |
| Scalability | 7 | Architecture scales well past the domain's ceiling |
| Supportability | 4 | Solo maintainer, bus factor 1 |
| Privacy compliance | 4 | Canada-hosted + honest posture; no retention/deletion tooling yet |

**Overall production readiness: ~4/10 — NOT production ready.** The architecture is ready; the *operations* are not. The path to ~7 is mechanical and known (§8 Critical/High + backups + monitoring), not a redesign.

---

## 11 · Missing Features (vs. modern union software)

| Feature | Why it matters | Who benefits | Priority | Complexity |
|---|---|---|---|---|
| Secure voting/ratification | Core union governance act | Members, leadership | High | High |
| Member self-serve portal | Reduces steward load; transparency | Members | High | Med |
| Communications (roster-aware, consent-based) | Mobilization, turnout | Leadership | High | Med |
| Grievance analytics (win-rates by article/employer) | Data-driven bargaining | Leadership | High | Med |
| Dues payment/reconciliation | Financial backbone | Treasurer | Med | High |
| Mobile-first steward tools | Reps work on the floor | Stewards | Med | Med |
| Anonymous tip/whistleblower intake | Surfaces issues safely | Members | Med | Low-Med |
| Offline/degraded verify | Job sites lack signal | Stewards | Med | Med |
| Bulk import / SSO / directory sync | Onboarding large locals | Admins | Med | Med |
| Accessibility (WCAG/AODA) conformance testing | Legal + inclusion | All | High | Low-Med |

---

## 12 · Competitive Analysis (architecture/positioning — no invented features)

**Categories:** legacy union-management suites, standalone voting platforms, member-comms tools, DMS, labour-relations/case software.

- **Strengths:** modern multi-tenant RLS core; passwordless/no-app member experience; **institutional-knowledge/continuity positioning** (differentiated — most tools are transactional CRMs); Canada-hosted data-residency; no-build simplicity → low operating cost; honest, union-culture-fluent messaging.
- **Weaknesses:** pre-revenue, unproven live, solo team, no integrations/SSO/mobile yet, no voting.
- **Differentiators:** (1) "the Local's memory" — grievance/CBA continuity across turnover, which incumbents treat as a filing cabinet; (2) member card + instant verify with no app/password; (3) architecture that lets one platform serve many locals cheaply.
- **Opportunities:** the tight union referral network; federation-level endorsement; a pooled, anonymized precedent library (a data moat no incumbent has); sector module packs.
- **Threats:** a parent/national body building in-house; incumbents adding "knowledge" features; trust barrier for an unknown vendor holding sensitive grievance data; long committee sales cycles.

**Positioning:** don't compete as "another union CRM." Compete as **the system of record for what the Local knows** — continuity, precedent, and verifiable membership — with the transactional features as table stakes underneath.

---

## 13 · Final Recommendations (as Chief Software Architect)

**Five most important engineering decisions**
1. **Keep RLS-first, header-scoped multi-tenancy with DEFINER-RPC anon reads.** It's the correct spine; standardize every new module on it.
2. **Unify on the no-build `steward-system` stack**; complete the `grievance-system` merge — do not maintain two front-ends.
3. **Make append-only + trigger-enforced integrity the default** for anything auditable (history, AI, and future voting).
4. **Parameterize all backend config** (kill hardcoded Supabase project) so multi-region and clones are safe.
5. **Introduce CI that runs `node --check` + the SQL isolation suites on a scratch DB** — tests that never run are not tests.

**Five highest risks**
1. Cross-tenant leakage (unproven live RLS). 2. Data loss (no backups on free tier). 3. The two-codebase / unapplied-migration drift. 4. Solo-maintainer bus factor. 5. Trust/security breach of grievance data with no pen test or IR plan.

**Five biggest opportunities**
1. Own "institutional knowledge/continuity" as a category. 2. CBA Intelligence + verified AI (the moat). 3. Federation-level distribution. 4. Pooled anonymized precedent library. 5. Sector module packs (dispatch/hours, seniority/recall, safety).

**Five things to complete before the first paying union customer**
1. **Apply `0022–0040` and pass all isolation suites live** (cross-tenant safety, proven).
2. **Turn on real backups + a tested restore** (Supabase Pro PITR).
3. **Reconcile `grievances` vs `grievance_cases`** and merge the grievance UI so the product matches the pitch.
4. **Add rate limiting + basic monitoring/error tracking** and a written incident-response + data-retention/deletion policy (PIPEDA/Law 25).
5. **Commission a third-party security/pen test** of tenant isolation, storage policies, and the anon RPC surface.

**Bottom line:** The Union Hub is architecturally sound and strategically well-positioned. It is **not** production-ready today — but the gap is a known, finite list of operational work, not a redesign. Do the five pre-customer items, and this becomes a defensible, category-defining platform.
