# The Union Hub — Consolidation Merge Plan (v1)

**Permanent home:** `steward-system` → Vercel project `the-union-hub-online` + its existing Supabase (deployed, live, working RLS).
**Being merged then archived:** `C:\X\grievance-system` — has never run against a live DB, so this is a **pure code merge, zero data migration**.
**Default rule:** where a concept exists on both sides, the **live app's version survives** (it's deployed and its RLS works).

> Status (updated 2026-07-06): decisions in §5 answered; migrations 0022–0030 written and staged in `supabase/migrations/` — **not yet applied to prod** (gated behind `docs/APPLY-RUNBOOK.md`). The original "PLAN ONLY, nothing executed" note is superseded.

---

## 1. Overlap inventory — what survives

| Concept | Live app (survivor) | grievance-system (source) | Decision |
|---|---|---|---|
| **Tenant resolver** | `get_request_tenant_id()` — reads client-set `x-tenant-id` header (subdomain → tenant) | `current_tenant_id()` — reads JWT `app_metadata.tenant_id` | **Live survives.** Grievance migrations rewritten to `get_request_tenant_id()`. `current_tenant_id()` discarded. |
| **Admin gate** | `is_request_tenant_admin()` (auth.uid() ∈ `tenant_admins` for header tenant) | `current_user_is_admin()` / `current_user_is_privileged()` (from `steward_profiles`) | **Live survives.** Grievance admin checks reconciled onto `is_request_tenant_admin()`. |
| **Tenants** | `tenants` (0001) — slug routing, `display_name`, `local_number`, `tenant_status` enum, accent, logo | `tenants` (0001) — minimal (name, slug) | **Live survives.** Grievance `tenants` create **discarded**; all grievance FKs repoint to live `tenants`. |
| **Members** | `members` (0002) — `status text 'active'`, tenant-scoped, RLS + admin RPCs (`admin_add_member`, bulk import) | `members` (0002) — rich: `employee_id`, `first/last_name`, `email`, `phone`, `job_classification`, `department`, `seniority_date`, `membership_status` enum, `custom_attributes`; + `member_history` | **Live survives as the base.** Grievance's extra columns **added via `ALTER TABLE`**; `member_history` added new. Grievance `members` create discarded. → **Decision D1 (status enum).** |
| **Roles / identity** | `tenant_admins` (role `admin`) + `stewards` (role tier `steward`/`unit_officer`/`executive`, `user_id` nullable) | `steward_profiles` (role `STEWARD`/`ADMIN`/`STAFF`) + `steward_coverage` | **Live survives.** `steward_profiles` + `steward_role` enum **discarded** (duplicate role system). `get_user_role()` reimplemented over live tables. `steward_coverage` kept but repointed. → **Decision D2 (STAFF).** |
| **Auth** | Passwordless **magic-link** (Supabase Auth OTP); admins via `tenant_admins`, stewards via `stewards.user_id` | Email/password (`Login.jsx`, AuthContext) | **Live survives.** Grievance SPA reworked to magic-link. → **Decision D6.** |
| **Audit logging** | `audit_log` (0004) — general system events (tenant lifecycle, admin actions) | `grievance_history` (immutable status audit) + `member_history` (field-level) | **Both kept — complementary, not duplicate.** `audit_log` stays general; the two domain histories are **added**. |
| **Grievance model** | `grievances` (0017) — *stub*: `member_name`, `grievance_type`, `status` (open/in-progress/resolved), `description` | `grievance_cases` (0003) — real model: steps INTAKE→ARBITRATION→CLOSED, deadlines, soft-delete, precedents, pipeline | **grievance_cases survives** as the real system of record; the live `grievances` **stub is deprecated**. → **Decision D3.** |
| **Document vault** | (none — storage used only for tenant logos) | `documents` (0008) + `union-docs` storage bucket | **Added** (new capability); repoint to live tenants + membership RLS. |
| **CBA / precedents / deadlines / notifications / pipeline view / ai_generations** | (none) | 0004, 0005, 0006, 0009, 0010 | **Added** (new); rewritten onto live tenancy + membership RLS. |

### The tenancy reconciliation (the crux)
The live app's proven pattern on every sensitive table is:
`tenant_id = get_request_tenant_id()  AND  (is_request_tenant_admin() OR user_id = auth.uid())`
— i.e. **header tenant + auth-membership**, so a spoofed header buys nothing (you still need to be an admin/steward of that tenant). Grievance-system's JWT-tenant model is replaced by adopting **exactly this pattern**. Two mechanics:

- **Client SPA calls:** the grievance React app sets the `x-tenant-id` header on its `supabase-js` client (computed from the subdomain), identical to how the steward front-end already does it → header-based RLS "just works," **no JWT `app_metadata` management, no new resolver, live app untouched.** → **Decision D5 (confirm).**
- **Membership predicate:** add one helper, `is_request_tenant_member()` = `auth.uid()` has a `stewards` row in the header tenant. Grievance policies become `get_request_tenant_id() AND (is_request_tenant_admin() OR is_request_tenant_member())`. This mirrors the `stewards`/`member_interactions` policies already in the live app (0013/0020).

---

## 2. Adapting grievance migrations 0001–0010 → live project (renumbered `0022+`)

The live project is at `0021`. Grievance migrations are **renumbered and rewritten**, not copied. Per source file:

| Grievance file | Becomes | Change |
|---|---|---|
| 0001 tenants + `current_tenant_id()` | — | **Discarded.** Use live `tenants` + `get_request_tenant_id()`. |
| 0002 members + `member_history` | `0022_members_extend.sql` | `ALTER public.members ADD COLUMN` for the grievance fields; **map/adopt status** (D1); add `member_history` table + trigger, RLS on `get_request_tenant_id()`. |
| 0007 steward RBAC | `0023_grievance_access.sql` | **No `steward_profiles`.** Reimplement `get_user_role()` → `ADMIN` if `is_request_tenant_admin()`, else `STEWARD` if a `stewards` row for `auth.uid()`, else none. Add `is_request_tenant_member()`. Keep `steward_coverage` but FK `user_id → auth.users` (or `stewards.user_id`). (D2) |
| 0003 grievance_cases + `grievance_history` | `0024_grievance_cases.sql` | Repoint `tenant_id`/`member_id` to live tables; RLS → header + membership; keep soft-delete + immutable history. Supersedes live `grievances` stub (D3). |
| 0009 cba_articles + grievance_precedents | `0025_cba_precedents.sql` | Repoint tenancy; server-stamped tenant/created_by preserved. |
| 0004 deadlines | `0026_grievance_deadlines.sql` | Repoint tenancy; rules/deadlines/triggers unchanged in logic. |
| 0005 pipeline view | `0027_grievance_pipeline.sql` | `security_invoker` view over reconciled tables. |
| 0006 notifications (outbox) | `0028_grievance_notifications.sql` | Repoint tenancy; service-role only, unchanged pattern. |
| 0008 document vault | `0029_document_vault.sql` | Repoint tenancy; add `union-docs` bucket + per-tenant-path storage RLS (mirror live logo-bucket pattern). |
| 0010 ai_generations | `0030_ai_generations.sql` | Repoint tenancy; RLS `get_request_tenant_id()` + `is_request_tenant_admin()`/own-row; append-only + cost columns unchanged. |

All rewrites drop `current_tenant_id()` / `current_user_is_*` / `steward_profiles` references in favour of the live app's functions + the one new `is_request_tenant_member()`.

---

## 3. Port the ai-service Edge Function + `ai_generations`

- Move `supabase/functions/{ai-service, _shared}` into the **live project's** `supabase/functions/`.
- `_shared/auth.ts`: `resolveIdentity()` keeps using `get_user_role()` — which now derives `(role, tenant_id)` from the **live** `tenant_admins`/`stewards` tables (server-side, unspoofable). The audit write still uses the service role, stamping `tenant_id`/`created_by` from that verified identity.
- `ai_generations` ships as migration `0030` (above), tenant-scoped to live `tenants`.
- Secret + deploy steps are already documented in `functions/ai-service/README.md`; nothing about them changes.
- Per-local cost tracking is preserved unchanged.

---

## 4. Discarded as duplicate scaffolding

From grievance-system, dropped in the merge (not ported):
- `supabase/migrations/0001_init_tenants.sql` (dup `tenants`) and the `current_tenant_id()` resolver.
- `steward_profiles`, `steward_role` enum, and grievance's `get_user_role()` / `current_user_is_admin()` / `current_user_is_privileged()` (parallel role system).
- The grievance `members` **create** (its fields are folded into live `members` via ALTER).
- Email/password auth (`Login.jsx` + password flows) → replaced by magic-link.
- The Vite SPA's `supabaseClient.js` tenancy assumptions (JWT app_metadata) → replaced by the `x-tenant-id` header pattern.
- After the merge lands and is verified: **`C:\X\grievance-system` is archived** (one repo, one Supabase, one deployment).

---

## 5. Decisions I need from you (before executing)

- **D1 — Member status.** Live `members.status` is free-text `'active'`; grievance used `membership_status` enum (`ACTIVE`/`RETIRED`/`ON_LEAVE`/`TERMINATED`). Keep live's `status` and **add** `membership_status` as a second column, or **fold** the four grievance states into the live `status` values? (Recommend: add `membership_status` column; leave `status` as-is so live verification/dues logic is untouched.)
- **D2 — STAFF role.** Live app has only `admin` (tenant_admins) + steward tiers. Grievance had a `STAFF` access role. Drop STAFF for v1 (map to STEWARD), or introduce a real staff concept now? (Recommend: drop for v1.)
- **D3 — Live `grievances` stub.** `grievance_cases` supersedes it. Drop the `0017` stub table + its admin page, or leave it dormant during transition? (Recommend: leave dormant, repoint the UI later — zero data, so no rush, and it de-risks the first deploy.)
- **D4 — Front-end port (the big one, see §6).** How does the grievance **React UI** reach the single deployment?
- **D5 — SPA tenancy.** Confirm the grievance SPA will set the `x-tenant-id` header (subdomain-derived) on its Supabase client, adopting the live pattern (my recommendation), rather than reintroducing JWT `app_metadata`.
- **D6 — Auth.** Confirm the grievance app moves to **magic-link** (no passwords), consistent with the live app and brand.

---

## 6. Out-of-scope of items 1–4 — the front-end consolidation (flag)

Items 1–4 are a **backend/schema + Edge Function** merge and are fully specified above. But "one deployment, forever" also implies the **front-ends** merge, and this is the larger, unaddressed question:

- The live app is **static HTML + ES modules + `@vercel/edge`** (no build step).
- grievance-system is a **Vite + React SPA** (build step, client router).

These are different stacks. Consolidating the *deployment* means one of:
1. **Rebuild** the grievance React pages as static/vanilla pages inside `steward-system` (largest effort, but truly "one stack").
2. **Serve the React SPA** from the same Vercel project under a path/subdomain (e.g. `app.` or `/grievances`), mixed static + SPA on one project (faster, two front-end stacks under one deploy).
3. **Keep the React app** as the front-end for the authenticated "operations" surface and the static app for the public/verification surface — one Vercel project, two build outputs.

The **backend merge in §§1–4 is valid regardless of which front-end path you choose** — the database + Edge Function become one Supabase project either way. I recommend we **land the backend merge first** (it's the reconciliation with real risk), verify RLS end-to-end, then choose the front-end path as a separate step. D4 is where you tell me which of the three you want — it doesn't block §§1–4.

---

_Prepared 2026-07-05. Execution begins only after §5 is answered._
