# DEMO & ENVIRONMENTS — The Union Hub

**Phase 12** · 2026-07-16 · Branch `release/v0.1-production-hardening`
**Covers:** the development environment, the demo environment, the demo dataset (Local 5000), the reset process, test accounts, and the three role demonstrations. (Staging is in `STAGING_ENVIRONMENT.md`; the walkthrough narrative is in `DEMO_SCRIPT.md`.)
**Hard rule:** demo/dev data is **physically separate** from production — its own Supabase project, its own keys. Nothing here can touch a real member.

---

## 1 · The environment trio (recap + dev)

| Env | Domain | Supabase project | Data | Who uses it |
|---|---|---|---|---|
| **Development** | `localhost` / `*.lvh.me:3000` | local (`supabase start`) or a scratch project | throwaway | developers |
| **Staging** | `staging.theunionhub.ca` | separate | synthetic | pre-prod validation |
| **Demo** | `demo.theunionhub.ca` (tenant `local5000.demo…`) | **separate** | fictional Local 5000 | sales, training |
| Production | `theunionhub.ca` | prod | real | customers |

### Development environment
- **Run locally with no cloud:** `npx --no-install supabase start` (local Postgres+Auth+Storage) → apply `0001–0040` → seed → serve the static app with `vercel dev` (or any static server; remember to **serve, don't `file://`**).
- Dev hosts resolve via `*.lvh.me` (→ 127.0.0.1) so subdomain→tenant routing works locally (`demo.lvh.me:3000` → tenant `demo`).
- Dev uses **local/scratch** Supabase keys only — never prod, never demo.
- Purpose: test changes safely before they ever reach staging.

## 2 · Demo environment

**Requirements met:**
- **Completely isolated** — its own Supabase project + its own Vercel project/domain. A demo mishap cannot reach production.
- **Reset capability** — one command reloads clean fictional data (§4).
- **Realistic fictional data** — Local 5000 (§3), MOCKUP-RULES-compliant.
- **Multiple roles** — Executive, Steward, Member test accounts (§5).

**Provisioning** (repeatable): create Supabase `theunionhub-demo` (ca-central-1) → apply `0001–0040` → run the demo seed (§3/§4) → Vercel demo project → `demo.theunionhub.ca` (+ `*.demo` if showing subdomains) → set demo Auth Site URL. Identical steps to staging, different project + seed.

## 3 · Demo data strategy — Local 5000 (fictional, per MOCKUP-RULES)

**Union:** Allied Health & Service Workers · **Local 5000** *(fictional parent — deliberately not "Ontario Public Healthcare Workers"; see MOCKUP-RULES)*. Riverbend region. Chartered 1961.

**Scale:** ~15,000 members · 120 stewards · **8 units** · **5 fictional employers** (Lakeview Regional Health Centre, Harbourview Health Sciences Centre, Northgate Long-Term Care, Riverbend Community Health, Westfield Homecare Services).

**Units:** Acute Care · Long-Term Care · Community Health · Diagnostic Imaging · Mental Health · Home & Community Care · Support Services · Paramedic/EMS.

**People (privacy-modelled):** bulk members generated as `Member #…` with realistic-but-generic varied names, full names visible only to authorized roles. Anchor cast kept exact:
- **Jordan Rivera** — membership story, case **GRV-2025-0017** (safety discipline).
- **Marcus Bennett** — case-management story, case **GRV-2026-0147** (attendance discipline).
- **E. Vance** — Chief Steward; plus a spread of generic stewards across the 8 units.
- Executive: M. Delgado (Pres), A. Kaur (VP), R. Whitefeather (Sec-Treas), T. Okafor (Rec-Sec).

**Institutional-memory content (the whole point of the demo):**
- **Historical grievances** across several years and multiple employers — enough that "how did we handle this last time?" returns real precedent. Includes the two anchor cases plus generated fictional cases spanning `INTAKE → … → CLOSED`, with outcomes.
- **Collective agreements** — fictional "Regional Healthcare Collective Agreement 2023–2026" + a prior 2020–2023 term, with `cba_articles` populated so precedent links resolve.
- **Documents** — fictional CA PDFs, grievance forms, H&S minutes (in the demo Storage bucket).
- **Voting examples** — *modelled as fictional past results only* (voting isn't built yet; the demo shows the concept as historical records, clearly labelled "sample," never a live ballot). **Do not imply voting is a shipped feature.**

**Data honesty (binding):** every aggregate stat (grievance counts, win rates) is a **labelled demo assumption**; dates internally consistent, anchored to mid-July 2026; nothing implies shipped-what-isn't.

## 4 · Demo reset system

A repeatable, idempotent reset so the platform can be demoed and trained on again and again.

**Design:** `supabase/demo/` in the repo (demo-only, never applied to prod):
- `demo_seed.sql` — truncates the demo tenant's tables (demo project only) and reloads Local 5000: tenant, units, employers, members (bulk-generated deterministically), stewards, historical grievances + history, CBA + articles, documents metadata, sample voting records.
- `demo_accounts.sql` — (re)creates the role test accounts (§5).
- `reset-demo.sh` — guarded wrapper: **refuses to run unless the target is the demo project** (checks the project ref), then runs the two scripts. The guard is the safety rail that makes "never touch production" structural.

**Usage:** `./reset-demo.sh` before each demo/training session → clean, known state in seconds. Idempotent: safe to run repeatedly.

**Guardrail:** the script hard-codes the demo project ref and aborts on mismatch; it also refuses if `SUPABASE_URL` resolves to the prod project. Reset is destructive **by design** — but only ever to demo data.

## 5 · Test accounts (per demo, three roles)

| Role | Account | Sees (demo) |
|---|---|---|
| **Executive** | `exec@local5000.demo` | Local dashboard, membership overview, active issues, steward activity, org-wide visibility |
| **Steward** | `steward@local5000.demo` (E. Vance) | Assigned members, grievance workflow, documents, deadlines, case history |
| **Member** | `member@local5000.demo` (Jordan Rivera) | Digital credential, profile, communications, resources |
| Read-only auditor | `auditor@local5000.demo` | Read-only org view (previews the Phase-6 role tier) |

Accounts use the demo Supabase Auth (magic-link to a shared demo inbox, or pre-provisioned sessions). Credentials documented in the demo project's private notes, never in the repo.

## 6 · What each environment is for (one line each)
- **Dev:** break things safely.
- **Staging:** rehearse production (incl. the migration apply) with synthetic data.
- **Demo:** show unions the value, and train new users — repeatable, resettable, fictional.
- **Production:** real locals, real members — nothing above ever touches it.

## 7 · v0.1 exit criteria (demo/env)
- Demo Supabase project live, `0001–0040` applied there, Local 5000 seeded.
- `reset-demo.sh` works and is guarded against prod.
- Three role accounts demonstrable end-to-end.
- `DEMO_SCRIPT.md` walkthrough runnable in ≤30 minutes.
