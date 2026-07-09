# The Union Hub — Member-ID Harvest Plan (v1, executed)

**Permanent home:** `steward-system` → Vercel project `the-union-hub-online` + its live Supabase.
**Harvested then archived:** `C:\X\member-id-system` — a React+Vite scaffold, **never wired to a live Supabase** (`0001_members.sql` never ran against production). Pure CODE harvest, zero data migration.
**Default rule:** where a concept exists on both sides, the **live app's version survives**; the scaffold is a **parts donor only**.

> Status: EXECUTED (Phase 1, 2026-07-05). Mirrors the structure of `MERGE-PLAN.md`. Numbering: `0031` is reserved (D5 members RLS hardening); identity-harvest migrations are `0032+`.

---

## 1. Overlap inventory — what survived

| Concept | Live app (survivor) | member-id-system (source) | Decision |
|---|---|---|---|
| **Members table** | `members` (0002 + 0023) — tenant-scoped, RLS, `membership_status` | `members` (`0001`) — single-tenant, text PK, `expires_on` | **Live survives.** Scaffold table + `verify_member` RPC **discarded** — not ported. |
| **Public verify RPC** | `lookup_member` (0008) — SECURITY DEFINER, column-whitelist, reads `get_request_tenant_id()` itself | `verify_member` — same idea but single-tenant | **Live survives** (already tenant-aware & superior). Extended in `0033` to also return `member_number`. |
| **Card / verify pages** | `tenants/_template/{card,verify}.html` — 5 card states, dues collected-verdict, tenant theming | React `/card`, `/verify` | **Live survives.** Scaffold's *logic/patterns* harvested into the live pages (below). |
| **QR** | vendored `lib/qrcode.js` (level H), unsigned URL | `qrcode.react`, unsigned URL | **Live survives.** (Signed tokens are Phase 2, not here.) |

## 2. What was harvested — and where each piece landed

| # | Harvested from scaffold | Landed in live app | Notes |
|---|---|---|---|
| 1 | Centralized verdict logic (`verdictFor`) | **`lib/verdict.js`** (new); imported by `tenants/_template/card.html` + `verify.html` | One source of verdict truth for both pages. `badgeHtml()` = the StatusBadge pattern (#3). |
| 2 | Dual-backend demo/live fetch | **`lib/member-fetch.js`** (new): `fetchMemberById(id, tenantId)` + `DEMO_MEMBER` | De-dups the identical inline fetch that was in both pages; demo mode issues no Supabase request. |
| 3 | `StatusBadge` reusable pattern | `badgeHtml(verdict)` in `lib/verdict.js`; used by `card.html` | Token-only, mapped from React to the static stack. |
| 4 | Distinct lapsed-vs-not-found copy | `lib/verdict.js` `detail` field; `verify.html` `renderInvalid(reason, detail)` | Mapped onto **existing** live statuses — **no new status values** (D1). |
| 5 | Member No. + valid-context rows | `card.html` renderCard: "Member No." row + "Card · Live · verified at scan" row; retired hardcoded `UH–2026–104873` footer | Backed by `member_number` (`0032`), surfaced by `lookup_member` (`0033`). |

## 3. Schema changes (migrations `0032`–`0033`)

- **`0032_member_number.sql`** — `members.member_number text`, **unique per tenant** (`uq_members_tenant_member_number`, partial), backfilled `M-<6-digit per-tenant sequence>`. **Display/print/read-aloud only** — all lookups and QR/verify URLs still key on `members.id` (uuid). Per-tenant format is documented and overridable; uniqueness is per-tenant, not format-bound. **No `expires_on` / valid-thru** was added — live status is the product's philosophy; a stated expiry reintroduces the stale-card model.
- **`0033_lookup_member_add_member_number.sql`** — `lookup_member` now returns `member_number` on its whitelisted shape (nothing else new; no PII exposed).

## 4. Security tests (required by Phase 1)

`supabase/tests/member_verify_isolation_test.sql` — self-contained, rolls back. Proves:
1. **Direct table reads denied** — anon and authenticated-non-admin get **0 rows** on a direct `SELECT` from `members` even with the correct tenant header (post-0008 there is no anon read policy; the RPC is the only public path).
2. **No cross-tenant resolve** — a verifier scoped to tenant A **cannot** resolve tenant B's member via `lookup_member` (empty result).
3. Positive control — the right tenant resolves the row and gets `member_number` back.

Run against a DB with `0001`–`0033` applied (`supabase db reset` then `psql -f`), same as `grievance_tenant_isolation_test.sql`.

## 5. Palette guard — promoted monorepo-wide

- **`scripts/lint-palette.mjs`** (new, root) + root **`package.json`** `lint:palette`: discovers every package under the monorepo root and walks each one's source (generalized off the scaffold's hardcoded `src/`). Rejects raw Tailwind colour scales and bare black/white.
- Wired into **steward-system's build** (`prebuild` → `lint:palette`). Current run: **clean** across the monorepo.

## 6. Demo content (MOCKUP-RULES)

- The `_template` card/verify **demo state** (no `?id=`) previously showed the **real** "Canadian Union of Public Employees". Recast to the canonical cast: **Jordan Rivera / Local 412 / M-100823** (`DEMO_MEMBER` in `lib/member-fetch.js`). On a resolved tenant subdomain the (fictional) tenant identity overlays it — no real union name ever appears.
- `MOCKUP-RULES.md` gained a **scope** line: it governs demo states inside the live product; real tenant data is out of scope.
- **Deferred** (see BACKLOG): the demo-tenant DB seed (`seed.sql`) still uses generic names; aligning it re-seeds live demo rows tied to the three demo UUIDs.

## 7. Archived

`C:\X\member-id-system` → **`C:\X\_archive\member-id-system`**, with a `HARVEST-POINTER.md` mapping each of the five harvested pieces to where it landed. Same treatment as the (pending) grievance-system archive. Its old local `lint:palette` is superseded by the root guard.

---

_Prepared & executed 2026-07-05. Phase 1 of the Identity Consolidation. Stops here for approval before Phase 2._
