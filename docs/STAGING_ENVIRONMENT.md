# STAGING ENVIRONMENT — The Union Hub

**Phase 12** · 2026-07-16 · Branch `release/v0.1-production-hardening`
**Principle:** three fully separate environments — **production**, **staging**, **demo** — each with its **own Supabase project** and **own domain**. Demo/staging data must **never** touch production. (Demo is specified in `DEMO_ENVIRONMENT.md`; this doc covers staging.)

---

## 1 · The three-environment model

| Environment | Domain | Supabase project | Data | Purpose |
|---|---|---|---|---|
| **Production** | `theunionhub.ca` | prod (real) | Real tenant/member data | Live customers |
| **Staging** | `staging.theunionhub.ca` | **separate** project (ca-central-1) | Synthetic test data | Final validation before prod |
| **Demo** | `demo.theunionhub.ca` (or a separate domain) | **separate** project | Fictional showcase data (Local 5000) | Sales demonstrations |

**Why separate Supabase projects, not just separate tenants:** a shared project means a migration bug, an RLS mistake, or a bad seed could reach real member data. Physical project separation is the only guarantee that "don't mix demo with production" is *structurally* true, not just policy.

**Cost note:** Supabase Free allows 2 projects and pauses on inactivity. Three environments → either Supabase **Pro** (recommended once there's a paying customer) or a mix (prod on Pro, staging+demo on Free, waking them as needed). Vercel: staging/demo as their own projects, or as long-lived preview branches.

## 2 · How the config already supports this
`lib/domains.js` is a **host→config registry** with per-region env layering (`serverConfigForHost`). Staging slots in cleanly:
- Add a `staging.theunionhub.ca` entry (or resolve it via env) pointing at the staging Supabase project.
- Set staging's `SUPABASE_URL` / `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY` in the staging Vercel project's env vars — **never** the prod values.
- `PUBLIC_BASE_DOMAIN=staging.theunionhub.ca` so subdomain tenant routing works within staging (e.g. `local183.staging.theunionhub.ca`).

No code fork required — staging is a configuration of the same codebase.

## 3 · Provisioning steps (repeatable)
1. **Supabase:** create `theunionhub-staging` in **ca-central-1**. Record URL + keys.
2. **Migrations:** apply `0001–0040` to staging via the APPLY-RUNBOOK (staging is the *rehearsal* for the prod apply — run it here first, every time).
3. **Seed:** load synthetic test data (test tenants, test members, test grievances) — see §5. Never a prod dump.
4. **Vercel:** a `theunionhub-staging` project (or a `staging` branch with its own env), custom domain `staging.theunionhub.ca`.
5. **DNS:** `staging` (and optionally `*.staging`) CNAME → Vercel.
6. **Auth:** set the staging Supabase Auth Site URL/redirects to `https://staging.theunionhub.ca` (or the magic-link flow breaks — same gotcha as prod).

## 4 · Test accounts & workflows
- **Test admin, test steward, test member** per test tenant, with known credentials (magic-link to a shared test inbox or Supabase test users).
- **Test documents** — synthetic, clearly marked, exercising the document vault + visibility gating.
- **Test workflows** — a full grievance lifecycle (INTAKE→…→CLOSED), a deadline that fires a notification, a verify (Verified/Not-valid/Not-found), a published site.

## 5 · Data policy (hard rules)
- **Never copy production PII to staging.** If prod-shaped data is needed, generate synthetic equivalents.
- Staging data is disposable and may be reset at any time.
- Staging uses its **own** anon/service keys; a leaked staging key can never touch prod.

## 6 · Promotion flow (how a change reaches production)
```
feature branch → merge to release/... → deploy to STAGING (staging Supabase + staging.theunionhub.ca)
   → run migrations here first (rehearsal) → run isolation suite + API smoke + manual QA
   → only then merge to main → production deploy → post-deploy /api/health + smoke check
```
Staging is where the APPLY-RUNBOOK is *rehearsed* so the production apply has no surprises.

## 7 · v0.1 exit criteria (staging)
- `staging.theunionhub.ca` live on a separate Supabase project, migrations `0001–0040` applied, isolation suite green there **first**.
- Test accounts for all three roles; a full grievance workflow demonstrable.
- Documented, repeatable provisioning (this file) so staging can be rebuilt from scratch.
