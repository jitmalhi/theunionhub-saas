# The Union Hub Access — Handoff

_Last updated: 2026-06-29_

This document covers the work done to take **TheUnionHub.online** from a steward-credential MVP to a fuller representation platform (credentials → grievances → knowledge capture → DFR logging → leadership analytics), plus the multi-domain (`.com`/`.ca`) infrastructure refactor.

---

## 1. Context & architecture

- **What it is:** a multi-tenant, no-build static SaaS on **Vercel + Supabase**. Plain HTML/CSS/ES-modules served statically, a small serverless API layer (`/api/*`), and one edge middleware. Only runtime dep is `@vercel/edge`; `npm run build` is a no-op.
- **Tenancy:** subdomain → tenant. The edge middleware ([api/_middleware.js](api/_middleware.js)) resolves the tenant and injects `x-tenant-id`; **Supabase RLS is the real security boundary** (`get_request_tenant_id()` reads the header GUC). Auth is **magic-link only** (no passwords).
- **Config source of truth:** [lib/supabase.js](lib/supabase.js) (zero-dep client) resolves Supabase URL/key. As of the multi-domain refactor, per-host config lives in [lib/domains.js](lib/domains.js).

### Cloud project & key identifiers
- **Supabase project (US / `.com`):** `https://frdvhmzbsmczknqtexvx.supabase.co`
- **Publishable anon key** (RLS-safe, intentionally public): `sb_publishable_mQ5Y9tjHHQmc9gCZPB_tHA_OwHXTc9P`
- **Demo tenant "Local 183":** `slug=local183`, `id=5d2b4b7e-672d-4057-a27e-f91dfad88af3`
- **Seeded reps (Local 183):** Eleanor Vance (executive) `…0010`, Marcus Bell (unit_officer) `…0011`, Priya Anand (steward) `…0012` — UUID prefix `a57e0a00-0000-4000-8000-0000000000xx`.

### Conventions to reuse (don't reinvent)
- Tenant-scoped data calls: `createClient({ tenantId: tenant.id })` then `.from(table)` / `.rpc(fn)` / `.raw(path)`.
- Admin pages gate with `requireAuth()` ([lib/auth-guard.js](lib/auth-guard.js)) + an **admin probe** (`list_tenant_admins()` raises `not_tenant_admin`).
- SECURITY DEFINER RPCs for anything RLS forbids a client to do (claim, transfer).
- Service-role writes go through a **server-side `/api` route** (never the browser) for anything members (anon) submit.
- The custom client has **no `.upsert()`** and **throws** on error (no `{ error }` return) — adapt snippets accordingly.

---

## 2. Database migrations

All in [supabase/migrations/](supabase/migrations/). **Applied via the Supabase SQL Editor** (no CLI/Docker in this workflow). Status verified live via REST audit on 2026-06-24 unless noted.

| # | File | Purpose | Cloud status |
|---|------|---------|--------------|
| 0013 | `0013_stewards.sql` | stewards + steward_analytics (pre-existing) | ✅ applied |
| 0014 | `0014_claim_representative.sql` | self-claim RPC (pre-existing) | ✅ applied |
| 0015 | `0015_steward_role.sql` | `stewards.role` tier: `steward`/`unit_officer`/`executive` (CHECK) | ✅ applied |
| 0016 | `0016_steward_role_guard.sql` | BEFORE UPDATE trigger: only admins may change `role` | ⚠️ user-confirmed applied; trigger negative-test needs an authed steward session |
| 0017 | `0017_grievances.sql` | grievances table, **admin-gated** RLS (tenant admin only) | ✅ applied |
| 0018 | `0018_knowledge_entries.sql` | knowledge capture, RLS = **author or admin** | ✅ applied |
| 0019 | `0019_transfer_knowledge_entry.sql` | SECURITY DEFINER transfer RPC (author/admin → in-tenant steward) | ✅ applied (re-applied via drop-then-create to fix a signature clash) |
| 0020 | `0020_member_interactions.sql` | **DFR log**: append-only, no anon/auth INSERT (service-role only), admin/self read | ✅ applied |
| 0021 | `0021_workplace_intelligence.sql` | admin-gated aggregation RPC (total/by_topic/by_worksite) | ✅ applied |

**Security guards verified live (anon):** DFR insert → `401` (blocked); `transfer_knowledge_entry` → `permission denied` (REVOKE FROM PUBLIC holds); `workplace_intelligence`/grievances → admin-gated.

> **Gotcha:** PostgREST caches its schema. After applying DDL, run `NOTIFY pgrst, 'reload schema';` or new tables/columns may 404 over REST briefly. We hit this more than once.

---

## 3. Features built

### 3.1 Steward role tiers (credential)
- `role` column (0015) + escalation-guard trigger (0016).
- Threaded `role` into the fetch + a **tier badge** on the public card ([tenants/_template/access.html](tenants/_template/access.html)) and the self-portal; `ROLE` added to the vCard. Outlined chip for steward/officer, **filled** for executive.

### 3.2 Public access card + hardened boot
- [tenants/_template/access.html](tenants/_template/access.html) — the QR-scan "verified representative" page.
- Boot was hardened: **force-resolve tenant → gate → fetch**, with per-step **timeouts** and a `finally` backstop so the page can never hang on "Loading…". (Root cause of an earlier hang was a malformed `try` that broke the whole module.)

### 3.3 Grievances (admin)
- [tenants/_template/admin/grievances.html](tenants/_template/admin/grievances.html) + [lib/admin-grievances.js](lib/admin-grievances.js). List + status filter + create form. **Admin-only** (gate + admin-gated RLS).

### 3.4 Knowledge Capture (steward)
- [tenants/_template/access/portal/knowledge.html](tenants/_template/access/portal/knowledge.html) — 3-prompt guided capture (Current State / Timeline / Handoff), readiness meter, compiled "Handoff Brief", scaffolding chips.
- Cloud persistence (insert-then-update; localStorage fallback). **My Captures** list (resume by clicking; `?entry=<id>` deep-link). **Transfer to another steward** via the 0019 RPC (inline email form).

### 3.5 Steward Card + Member View + DFR log
- **Steward Card** [tenants/_template/access/portal/card.html](tenants/_template/access/portal/card.html) (`/access/portal/card`): flip card (identity + QR front / Representation Ledger back), QR encodes `/meet/<steward_id>`, **Active Representation** = last 3 captures.
- **Member View** [tenants/_template/access/meet.html](tenants/_template/access/meet.html) (`/meet/<steward_id>`): "You are meeting with [Steward], Authorized Steward of [Local]" + 3-step interaction log (Yes/No · Topic · next-steps affirmation) → success. Built high-contrast for a noisy floor.
- **Writer** [api/log-interaction.js](api/log-interaction.js): service-role insert into `member_interactions` (the un-forgeable DFR record).
- Middleware route added: `/meet/<id>` → `meet.html` ([api/_middleware.js](api/_middleware.js)).

### 3.6 Workplace Intelligence (admin analytics)
- [tenants/_template/admin/intelligence.html](tenants/_template/admin/intelligence.html) (`/admin/intelligence`) + [lib/admin-intelligence.js](lib/admin-intelligence.js).
- Total/Confirmed tickers, **CSS bar chart** (top friction topics), **worksite heatmap**, **window switcher** (7/30/90 days, shared loader with graceful loading/error states). Data from the admin-gated `workplace_intelligence(p_days)` RPC.
- **Representation Activity** drill-down [tenants/_template/admin/activity.html](tenants/_template/admin/activity.html) (`/admin/activity`): per-row DFR records (embed `steward:stewards(...)`), topic filter; linked from the Intelligence header.

### 3.7 Health probe
- [api/health.js](api/health.js) (`/api/health`): non-sensitive readiness (`200`/`503`) — reports whether `SUPABASE_URL` + a real (non-placeholder) service-role key are set, region-aware. Never echoes secrets.

### 3.8 Navigation
- `Grievances` and `Intelligence` links propagated across all 10 admin pages (`Dashboard · Members · Grievances · Intelligence · Team · Audit · Settings · Access`). Activity is reachable from the Intelligence header (intentionally not in the global subnav).
- `My Steward Card` link added to the steward portal.

---

## 4. Multi-domain (`.com` / `.ca`) infrastructure

Refactor so one codebase serves both country domains, each with its **own Supabase project** (Canadian data residency), chosen by **request host**.

- **New:** [lib/domains.js](lib/domains.js) — the host→config registry (`configForHost`, `serverConfigForHost`, `apexForHost`). `.com` entry holds the exact former `PROD_FALLBACK_*` values, so **`.com` behavior is identical** (16/16 assertions passed). [lib/reserved-slugs.js](lib/reserved-slugs.js) — de-duplicated the triplicated `RESERVED_SLUGS`.
- **Refactored to use the registry:** [lib/supabase.js](lib/supabase.js), [lib/tenant.js](lib/tenant.js), [api/_middleware.js](api/_middleware.js), [api/access-event.js](api/access-event.js).
- **Region-safety:** `serverConfigForHost` honors legacy unsuffixed env (`SUPABASE_URL`, …) **only for the default region** (`.com`); a non-default region reads its own **suffixed** vars (`SUPABASE_URL_CA`, `SUPABASE_ANON_KEY_CA`, `SUPABASE_SERVICE_ROLE_KEY_CA`) or the registry — so a single global env can never leak into `.ca`.
- **`.ca` is a placeholder** in the registry (empty url/key) until the Canadian Supabase project exists; a `.ca` host fails loudly rather than silently using the US project.

### To stand up `.ca` later
1. Create the Canadian Supabase project; fill its `supabaseUrl` + `anonKey` in the `.ca` entry of [lib/domains.js](lib/domains.js).
2. Set `SUPABASE_*_CA` env vars in Vercel; **leave `PUBLIC_BASE_DOMAIN` UNSET in production** so the per-host registry drives both domains (it only overrides apex for local dev like `lvh.me`).
3. Apply **all** `supabase/migrations/` to the CA project (schema drift between regions is the main risk).
4. Add `theunionhub.ca` + `*.theunionhub.ca` as domains on the Vercel project; add `.ca` redirect URLs to the CA project's auth allow-list.

---

## 5. ⚠️ Outstanding / go-live checklist

1. **`SUPABASE_SERVICE_ROLE_KEY` — local set, Vercel still pending.** Set in [.env.local](.env.local) on 2026-06-29 with the real `.com`-project (`frdvhmzbsmczknqtexvx`) `service_role` key (JWT verified `role:service_role`; file is gitignored). **Still must be added to Vercel env (Production + Preview) and redeployed** — until then the two service-role writers fail with `server_misconfigured` in production:
   - `/api/log-interaction` (DFR logs)
   - `/api/access-event` (scan analytics)
   Everything else works without it. `/api/health` returns `503` until the Vercel var is set + redeployed, `200` after. Scope note: the plain (unsuffixed) var drives only the default `.com` region; `.ca` needs its own `SUPABASE_SERVICE_ROLE_KEY_CA` (§4), so no leak risk.
2. **No browser verification yet.** All verification this session was `node --check` (syntax) + live REST/DB audits. The rendered pages have **not** been opened end-to-end (running `vercel dev` needs a Vercel login, unavailable in the working environment). **Recommended smoke test after setting the key:** open `local183.theunionhub.com/meet/a57e0a00-0000-4000-8000-000000000010`, submit → expect `201` + a new row in `/admin/activity` and `/admin/intelligence`.
3. **0016 trigger negative-test** (a non-admin steward cannot change `role`) hasn't been run — it needs an authenticated steward session.
4. **Notifications are NOT wired.** The member-view success copy was deliberately softened to "…now on record for your union representative" (no false "notified" claim). Wire a provider if real-time notification is wanted.
5. **`.ca`** — registry placeholder pending the Canadian project (see §4).

---

## 6. How to apply / verify / run

- **Apply migrations:** paste the migration SQL into Supabase → SQL Editor → Run. They're idempotent (`IF NOT EXISTS` / `OR REPLACE` / `DROP POLICY IF EXISTS`). After DDL, run `NOTIFY pgrst, 'reload schema';`.
- **Re-create a function that may already exist with a different signature:** drop all overloads first (a `DO` loop over `pg_proc`), then `CREATE` — `CREATE OR REPLACE` cannot change return type/param names (this bit us on 0019).
- **Local dev:** `.env.local` points the **server** (middleware + `/api`) at the cloud project; the **browser** always uses the registry fallback (cloud). `npm run dev` only serves static files — use `vercel dev` (needs login) for middleware + `/api`. Visit tenant pages via `local183.lvh.me:3000/...`.
- **Audit readiness:** `curl -s https://<tenant>.theunionhub.com/api/health | jq` → `ready:true` when config is set. Deeper object/security checks were done with anon-key REST probes (table existence, RPC existence, anon write/exec blocked).
- **Syntax-check an embedded page module:** extract the `<script type="module">` body and `node --check` it (HTML can't be checked directly).

---

## 7. File inventory (this session)

**New — SQL:** `0015_steward_role.sql`, `0016_steward_role_guard.sql`, `0017_grievances.sql`, `0018_knowledge_entries.sql`, `0019_transfer_knowledge_entry.sql`, `0020_member_interactions.sql`, `0021_workplace_intelligence.sql`; snippet `supabase/snippets/seed_local183_reps.sql`.

**New — lib:** `lib/domains.js`, `lib/reserved-slugs.js`, `lib/admin-grievances.js`, `lib/admin-intelligence.js`.

**New — pages:** `tenants/_template/admin/grievances.html`, `tenants/_template/admin/intelligence.html`, `tenants/_template/admin/activity.html`, `tenants/_template/access/portal/knowledge.html`, `tenants/_template/access/portal/card.html`, `tenants/_template/access/meet.html`.

**New — api:** `api/log-interaction.js`, `api/health.js`.

**Changed:** `lib/supabase.js`, `lib/tenant.js`, `api/_middleware.js`, `api/access-event.js` (registry refactor + `/meet` route + DEBUG-log cleanup); `tenants/_template/access.html` (role badge + hardened boot); `tenants/_template/access/portal/index.html` (role badge + My-Card link); all admin pages (subnav links); `.env.local` (cloud, with service-role placeholder).

---

## 8. Suggested next steps
1. `SUPABASE_SERVICE_ROLE_KEY` is set in `.env.local` (2026-06-29); **add it to Vercel env (Prod + Preview) and redeploy**, then run the `/meet` smoke test and confirm `/api/health` → `200`.
2. Browser-verify the new pages end-to-end with a real admin + steward magic-link session.
3. Decide on notifications (wire a provider, or keep the recorded-only model).
4. When ready, stand up the `.ca` Supabase project and fill the registry.
