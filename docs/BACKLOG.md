# Backlog — post-merge cleanup & follow-ups

Tracked so decisions from the consolidation (see `docs/MERGE-PLAN.md`) don't quietly live forever.

## From the grievance-system merge (2026-07-05)

- [ ] **Retire the dormant `grievances` stub (D3).** The `0017` `grievances` table + its admin page were kept dormant; `grievance_cases` (migration `0024`) is the real system of record. Once the grievance-case UI is wired and verified, migrate off the stub and drop the table + repoint/remove the old admin grievances page.
- [ ] **Harden live `members` RLS to header + membership (D5) — ships as `0031`, its own deploy.** The existing `members` policy is header-only (`tenant_id = get_request_tenant_id()`); grievance tables already require `is_request_tenant_member()`, and members should reach the same bar. Deliberately **not** bundled into the 0022–0030 merge (no silent live-behavior change inside a big merge). Gated behind the rollout sequence below. Must include a test proving a **tenant-A user sending tenant-B's header gets 403 on `members`** — the same guarantee the grievance tables already have — and a check that no anon/public path (QR card/verify) depends on header-only member reads.

### Rollout sequence (one change at a time)
1. **Apply the merge:** migrations `0022`–`0030` + deploy `ai-service` to the live project.
2. **Verify existing live behavior is intact** *before* anything else: QR **verification** flow (verified/not-valid/not-found), the **service-role writers** (`/api/log-interaction` DFR, `/api/access-event` scans), and `/api/health` → `200`. Plus the new D5 isolation test passes.
3. **Only then** ship `0031` (members RLS hardening) as a **separate deploy**, with its own 403-on-`members` test (per the item above).
- [ ] **Front-end consolidation (D4, option 2).** Stand the grievance **React SPA** up on the `the-union-hub-online` Vercel project (own subdomain/path). All future authenticated ops features build in the SPA — no parallel static rebuilds.
- [ ] **SPA auth → magic-link (D6).** Replace the grievance app's email/password login with Supabase magic-link, consistent with the live app.
- [ ] **SPA tenancy (D5).** The SPA sets `x-tenant-id` (subdomain-derived) on its `supabase-js` client. RLS + `is_request_tenant_member()` do the authorization; the header is never trusted alone.
- [ ] **Archive `C:\X\grievance-system`** once the merged migrations + ai-service are verified live. **Gate not yet met** (migrations 0022–0030 not yet applied/verified against live Supabase) — leave it in place until then.

## Migration numbering registry

Reserved / used slots, so parallel work doesn't collide. Update this when you claim a number.

| Slot | Status | What |
|---|---|---|
| `0001`–`0021` | applied (live) | Base platform (tenants, members, RLS, stewards, verifications, dues, audit). |
| `0022`–`0030` | merged, **pending apply** | grievance-system consolidation (see MERGE-PLAN.md). |
| `0031` | **RESERVED** | members RLS hardening (D5) — header + membership. Ships as its own deploy per the rollout sequence above. **Do not reuse.** |
| `0032` | added (Phase 1) | `member_number` (human-readable, per-tenant unique, display-only). |
| `0033` | added (Phase 1) | `lookup_member` returns `member_number`. |
| `0034` | added (Fable fix #3) | `lookup_steward` RPC + drop anon direct read on stewards. |
| `0035` | added (Fable fix #6) | `member_number` auto-assign trigger + per-tenant counter. |
| `0036` | added (Tier-1 websites) | `site_settings` + `tenant_hostnames` + `site_is_published`/`resolve_site_tenant`. |
| `0037` | added (Tier-1 websites) | `site_alerts/posts/officers/stewards/meetings/documents` + published-gated RLS. |
| `0038` | added (Tier-1 websites) | `get_public_site(tenant)` — whole published site as one jsonb blob for the edge renderer. |
| `0039` | added (Tier-1 websites) | `export_site()` — admin-gated full-site JSON export (content-ownership). |
| `0040` | added (OCR/knowledge pipeline) | `source_documents` + `document_extractions` + verify-gate RLS (see docs/OCR-KNOWLEDGE-PIPELINE.md). |
| `0041+` | free | next (pipeline: storage bucket + extract-document edge function; Tier-1 custom domains). |

> **Note:** `0036+` (Tier-1 hosted websites) is a **separate feature line** from the 0022–0035 grievance-merge + security-fix batch. It has its own apply/verify path and is **not** part of `docs/APPLY-RUNBOOK.md`.

## From the member-id harvest (Phase 1, 2026-07-05)

See `docs/MEMBER-ID-HARVEST-PLAN.md`. Friction noted here rather than acted on:

- [ ] **Dual status columns on `members`.** Live `status` (`active|inactive|suspended|pending`, what card/verify branch on) and `membership_status` (enum `ACTIVE|RETIRED|ON_LEAVE|TERMINATED`, from 0023) coexist with different vocabularies and casing. Per D1 both were left untouched. Decide a single source of truth (or a documented mapping) before either drives new UI.
- [ ] **`pending` verdict.** The shared verdict (`lib/verdict.js`) now maps `pending` → inactive card / not-valid verify (it previously rendered as *not found* on the card — a latent bug). Confirm this is the desired treatment for pending members, or split `pending` into its own screen.
- [ ] **Demo-tenant seed vs MOCKUP-RULES.** Phase 1 recast the client-side **demo state** (no `?id=`) to the canonical cast (Jordan Rivera / Local 412 / M-100823). The **demo-tenant DB seed** (`supabase/seed.sql`) still carries generic names ("Demo Member · Active", steward "Maya Okonkwo", local "000"). Those are demo content too and should be aligned to the cast — deferred because it re-seeds live demo rows and the three demo UUIDs are referenced by `card.html`/`verify.html` (keep them in sync).

## Fable 5 review (2026-07-06)

Full review lives in the session; findings tracked here so they don't evaporate.

**Fixed same day (Phase 1.1 correction, pre-apply):**
- [x] **#2 (Critical)** — live "Mark as paid" always failed: `verify.html` `markMemberPaid` passed the extras object as the tenantId arg (`sbHeaders({…})`). Regression from the harvest replace-all missing a 6-space-indented call. Now `sbHeaders(currentTenantId, {…})`.
- [x] **#7 (Critical)** — stored XSS: `card.html`/`verify.html` injected member fields into `innerHTML` unescaped under a `'unsafe-inline'` CSP. Added `lib/escape.js`; `full_name`/`union_name`/`local_number`/`member_number`/badge label/`reason` now `esc()`-wrapped.
- [x] **#1 (Critical)** — QR verify URL used `pathname.replace(/card\.html$/,'')` → `/cardverify.html` (404) on pretty `/card` URLs. Now `${location.origin}/verify?id=…`; stray `index.html` links → `/`. **Still needs a real-deploy scan test.**
- [x] **#5 (High)** — immutable 1-yr cache on all JS/CSS in a no-fingerprint system would pin bugs. `/lib` + `/css` now `max-age=0, must-revalidate`; immutable kept only for fonts/images.

**Fixed 2026-07-06 ("fix everything you can" pass):**
- [x] **#3 (Critical)** — steward-PII harvest closed: migration **0034** drops anon's direct SELECT on stewards and adds `lookup_steward(p_id)` (SECURITY DEFINER, tenant-scoped, public columns only); `access.html` + `meet.html` rewired to the RPC; `steward_lookup_isolation_test.sql` proves it. (The world-readable `tenants` table is a separate, lower-severity item — see #3-residual below.)
- [x] **#6 (High)** — `member_number` now auto-assigns on every insert via migration **0035** (per-tenant counter + BEFORE INSERT trigger, seeded above the 0032 backfill max, collision-safe). The false "safe to re-run" comment in 0032 corrected.
- [x] **#4 (partial)** — the false "un-forgeable" claim in `log-interaction.js` rewritten to be honest (attributable, not forgery-proof). **Still deferred:** actual rate limiting + provenance columns (needs a store/design).
- [x] **#9** — deleted orphaned `src/lib/aiService.js` (Vite/React file, broken import, unused) + its empty dirs. (grievance-system archive stays deferred — its gate isn't met; see #9-residual.)
- [x] **#11** — region accuracy: docs (`GO-LIVE`, `APPLY-RUNBOOK`, `MERGE-PLAN` context) + `lib/domains.js` clarified that `region:'us'` is an env-namespace key and the project physically runs in `ca-central-1`. (Label value intentionally unchanged — it namespaces env vars.)
- [x] **#13** — recast CUPE/USW/UFCW/IBEW/UNIFOR + fabricated testimonials to a fictional cast (Healthcare Workers Local 412, Transit Workers 88, …) across `steward-system/Brand/brandbook.html`, `admin/settings.html`, and the internal `brand/*` files.
- [x] **#14** — doc rot: MERGE-PLAN "PLAN ONLY" superseded; README tenancy contract rewritten to the header/`get_request_tenant_id` model (JWT-claim model noted as not-adopted); `admin-members.js:135` corrected; `card.html` CTA comment fixed; `health.js` "planned" → "live"; `migration_version` bump target set to `0035` (post-apply follow-up).
- [x] **#16** — removed the dead Cloudflare-only `cf:{cacheTtl}` fetch option + its wrong "Vercel honours this" comment in `api/_middleware.js`.

**Still deferred:**
- [ ] **#3-residual** — `tenants` is world-readable (`USING(true)`), so anon can still enumerate tenant UUIDs + read display_name/local_number/accent/logo. Lower severity now that stewards + members are RPC-only, but decide whether to narrow it.
- [ ] **#4-residual** — rate limiting + auth/provenance on `log-interaction`/`access-event`/`mark_member_paid`/`record_verification`.
- [ ] **#9-residual** — archive `grievance-system` once its migrations are applied+verified (gate not yet met).
- [ ] **#10** — ai-service has no rate limit / per-tenant budget; defaults to max settings; unpinned SDK; `pricing.ts` logs $0 for unknown models.
- [ ] **#12** — palette guard only matches Tailwind classes, never opens `.css`, and Vercel's `buildCommand` override bypasses the npm `prebuild`. Make it scan raw hex + wire it into the deploy, or drop the pretense.
- [ ] **#15/#18** — grievance isolation test only exercises helpers not policies; add a front-end smoke test of card→QR→verify→mark-paid; decide whether prod tenants should land on the demo switcher.

## Process notes

- **Isolation tests (`supabase/tests/`) must be re-run — and their setup re-checked — whenever the schema they set up against changes.** These tests hand-roll INSERTs for their fixtures (tenants, members, stewards, auth.users), so a new NOT-NULL column, CHECK constraint, or renamed column silently breaks the *setup*, not the assertion. Example (2026-07-05): `grievance_tenant_isolation_test.sql` failed at its first `INSERT INTO public.tenants` because `contact_email` (NOT NULL + format CHECK, present since 0001) wasn't supplied; fixed by matching `member_verify_isolation_test.sql`'s tenant insert. When a migration alters a table a test seeds, update every test's setup for that table in the same change.
