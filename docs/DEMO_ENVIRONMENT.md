# DEMO ENVIRONMENT — The Union Hub

**Updated 2026-07-19 — architectural change:** the demo is now a **first-class tenant**, not a separate environment or mode. *(This supersedes the earlier "physically separate Supabase project" model.)*
**Data source of truth:** `UX design/MOCKUP-RULES.md` → the demo tenant section.

---

## 1 · The decision
The demo is **just another tenant** in the same database as every customer, isolated by the **same RLS** (the isolation validated in `TENANT_SECURITY_VALIDATION.md`). There is **no demo mode, no demo flag, no demo routing, no demo auth, no conditional logic.** The application cannot tell a demo tenant from a paying customer — **only the data differs.**

## 2 · Why this is better
- **Dogfoods real isolation.** The demo runs on the exact RLS that protects customers, so demoing *is* a live proof the boundary holds.
- **No drift, no special paths.** Every feature is demonstrated exactly as a customer experiences it — nothing can work in "demo mode" but break for real tenants.
- **Better testing.** The demo tenant is a permanent integration test of the real multi-tenant architecture.
- **Simpler.** One code path, one auth model, one navigation.

## 3 · The demo tenant
- **Slug:** `demo` *(confirmed NOT a reserved slug)* · **Subdomain:** `demo.theunionhub.ca` — resolves via the normal `subdomain → x-tenant-id → RLS` path, like any tenant.
- **Display name:** **Demo – Local 79** *(fictional demonstration tenant — NOT CUPE Local 79; see `MOCKUP-RULES.md`. Structure only, no real data.)*
- **Structure:** a large municipal / public-sector local — Executive Board, Chief Steward, Unit Stewards, multiple bargaining units / departments, grievances, arbitrations, a collective agreement, sample policies, sample members. Realistic in *shape*, entirely fictional in *content*.

## 4 · No special code (architecture requirement)
- The demo tenant uses the standard tenant resolution + RLS + auth. Nothing in `api/`, `lib/`, or the tenant templates branches on "is this the demo."
- **Separate concern — the apex marketing showcase:** the public marketing page's "see the live card" (`/card?state=…`), the `.demo-bar` toolbar in `card.html`, and the demo-cast fallback in `lib/member-fetch.js` / `lib/live.js` exist to show a card *on the apex with no tenant*. That is **marketing chrome, not tenant-app code**, and it does not make any tenant special. **Optional follow-up:** repoint the marketing "live demo" links at the real demo tenant (`demo.theunionhub.ca`) and retire the fallback — tracked, not required for this change.

## 5 · Data (fictional only)
Populated per `MOCKUP-RULES.md`. **No real member information. No confidential grievances. No real executive discussions.** Members shown as `Member #…` with fictional, varied names; fictional employers, grievances, meetings, documents. Obviously fictional, accurately shaped.

## 6 · Reset
Reset re-runs the **demo seed**, which is **scoped to the demo tenant only** — it deletes and reloads rows *where `tenant_id = <demo tenant id>`* and **never touches another tenant's rows**. (This is safe for exactly the reason the platform is safe: tenant isolation. The seed resolves the demo tenant by slug and filters every statement by that id.)

## 7 · Future customers
When a real Local becomes a customer: **create a brand-new tenant** and import *their* real members, grievances, documents, collective agreements, and executive users. The **demo tenant is untouched** and keeps serving demonstrations. **There is never any migration from the demo tenant into a customer tenant.**

## 8 · Relationship to dev / staging
- **Development** — local (`supabase start`) or scratch DB; throwaway.
- **Staging** — a separate pre-prod project for rehearsing migrations (`STAGING_ENVIRONMENT.md`) — unchanged.
- **Demo** — a **tenant in the same database as customers** (production), isolated by RLS. Safe because tenant isolation is enforced by the database (see `TENANT_ISOLATION_TESTING.md` / `TENANT_SECURITY_VALIDATION.md`) and because it holds only fictional data. There are no real customers yet, and the isolation gate governs go-live.

## 9 · Test accounts (standard tenant auth — no demo auth)
Sign in to `demo.theunionhub.ca/admin` with a magic link to a demo mailbox, exactly as any customer admin would. Suggested demo roles to provision (as normal tenant users/records, not special accounts): an Executive/officer admin, a Chief Steward, a member. Credentials kept in the demo project's private notes, never in the repo.

## 10 · Deliverables status
- [x] Architecture decision: demo = first-class tenant (this doc).
- [ ] Demo tenant seed (`supabase/demo/`) — rich fictional "Demo – Local 79" data, scoped to the demo tenant.
- [ ] `MOCKUP-RULES.md` updated to the "Demo – Local 79" tenant identity.
- [ ] Confirm no demo-specific code paths remain in the tenant app (marketing showcase noted separately in §4).
