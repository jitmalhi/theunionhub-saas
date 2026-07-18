# DEMO & ENVIRONMENTS — The Union Hub

**Phase 12** · 2026-07-16 · Branch `release/v0.1-production-hardening`
**Covers:** development, demo environment, the demo dataset, the reset process, test accounts, and the three role demonstrations. (Staging → `STAGING_ENVIRONMENT.md`; walkthrough → `DEMO_SCRIPT.md`.)
**Single source of truth for all demo data** (union, members, employers, locations, agreements, grievances, documents): **`UX design/MOCKUP-RULES.md` → "Large enterprise demo tenant (Local 5000)".** This doc does not restate that data; it references it.
**Hard rule:** demo/dev data is **physically separate** from production — its own Supabase project, its own keys. Nothing here can touch a real member.

---

## 1 · The environment trio (recap + dev)

| Env | Domain | Supabase project | Data | Who uses it |
|---|---|---|---|---|
| **Development** | `localhost` / `*.lvh.me:3000` | local (`supabase start`) or scratch | throwaway | developers |
| **Staging** | `staging.theunionhub.ca` | separate | synthetic | pre-prod validation |
| **Demo** | `demo.theunionhub.ca` (tenant `local5000`) | **separate** | fictional **Local 5000 · Cedarline** | sales, training |
| Production | `theunionhub.ca` | prod | real | customers |

### Development environment
- **Run locally, no cloud:** `npx --no-install supabase start` → apply `0001–0040` → seed → serve with `vercel dev` (serve, don't `file://`).
- `*.lvh.me` resolves to 127.0.0.1, so subdomain→tenant routing works locally (`local5000.lvh.me:3000`).
- Dev uses **local/scratch** keys only — never prod, never demo.

## 2 · Demo environment

**Requirements met:** completely isolated (own Supabase project + own Vercel/domain) · reset capability (§4) · realistic fictional data (Local 5000 · Cedarline, per MOCKUP-RULES) · multiple roles (§5).

**Provisioning (repeatable):** create Supabase `theunionhub-demo` (ca-central-1) → apply `0001–0040` → run the demo seed (§3/§4) → Vercel demo project → `demo.theunionhub.ca` → set demo Auth Site URL. Same steps as staging; different project + seed.

## 3 · Demo data — Local 5000 · Cedarline Health Workers Union

**The canonical definition lives in `MOCKUP-RULES.md`.** In brief: a **distinct fictional union** — *Cedarline Health Workers Union (CHWU) · Local 5000*, Port Hadley (fictional), chartered 1961, **~15,000 members · 120 stewards · 8 units · 6 fictional employers**. Its own cast (President L. Marchetti; Chief Steward C. Adeyemi; anchor members M. Thibault, R. Castellanos) — **separate from Local 412's cast**.

The seed must populate enough **institutional-memory** content to make the demo land:
- **Historical grievances across years and employers**, incl. the anchor precedent pair — **GRV-2026-0231** (open, Art. 14 attendance) and **GRV-2021-0088** (the same article, won under a *prior* Executive). This pair is the demo's core "how did we handle this last time?" moment.
- **Two collective-agreement terms** (2023–2026 current, 2020–2023 prior) with `cba_articles` populated so precedent links resolve.
- **Documents** (CA PDFs, bylaws, grievance form, H&S minutes, a sample arbitration decision) in the demo Storage bucket.
- **Voting** as **sample historical records only** — never a live ballot (voting isn't built).

**Binding honesty:** aggregate stats are labelled demo assumptions; privacy modelled (`Member #…`); dates consistent to mid-July 2026. See MOCKUP-RULES.

## 4 · Demo reset system

Repeatable, idempotent reset so the platform can be demoed and trained on again and again — `supabase/demo/` (demo-only, never applied to prod):
- `demo_seed.sql` — truncates the demo tenant's tables (demo project only) and reloads Local 5000 exactly per MOCKUP-RULES: tenant, units, employers, bulk members (deterministically generated), stewards, historical grievances + history, both CA terms + articles, document metadata, sample voting records.
- `demo_accounts.sql` — (re)creates the role test accounts (§5).
- `reset-demo.sh` — **guarded** wrapper: aborts unless the target project ref is the demo project (and refuses if `SUPABASE_URL` resolves to prod), then runs the two scripts. The guard is what makes "never touch production" structural, not just policy. Reset is destructive **by design — to demo data only.**

**Usage:** `./reset-demo.sh` before each session → clean, known Local 5000 state in seconds.

## 5 · Test accounts (three roles + auditor preview)

| Role | Account (demo) | Sees |
|---|---|---|
| **Executive** | `exec@local5000.demo` (L. Marchetti) | Local dashboard, membership overview, active issues, steward activity, org visibility |
| **Steward** | `steward@local5000.demo` (C. Adeyemi) | Assigned members, grievance workflow, documents, deadlines, case history + precedent |
| **Member** | `member@local5000.demo` (M. Thibault) | Digital credential, profile, communications, resources |
| Read-only auditor | `auditor@local5000.demo` | Read-only org view (previews the Phase-6 role tier) |

Demo Auth: magic-link to a shared demo inbox or pre-provisioned sessions. Credentials kept in the demo project's private notes, never in the repo.

## 6 · Purpose (one line each)
- **Dev:** break things safely. **Staging:** rehearse production (incl. the migration apply). **Demo:** show the value + train users, repeatably. **Production:** real locals — nothing above ever touches it.

## 7 · v0.1 exit criteria (demo/env)
- Demo Supabase project live, `0001–0040` applied there, Local 5000 seeded per MOCKUP-RULES.
- `reset-demo.sh` works and is guarded against prod.
- Three role accounts demonstrable end-to-end; `DEMO_SCRIPT.md` runnable in ≤30 min.
