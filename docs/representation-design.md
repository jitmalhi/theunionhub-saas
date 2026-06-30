# Representation & the Member Hub — Design Doc

**Status:** Draft for review. No code written yet.
**Scope:** The data model, RPCs, routing, and page flow for turning the Digital ID
from a verification artifact into the member's "front door" — starting with the
representation spine (`/access/:uuid`, "My Steward"), and mapping the broader
feature vision onto it.

---

## 1. The reframe

Today the product is one stateless read keyed by a member UUID:

```
Digital ID  →  Verify Membership
```

The direction is to make the card a launcher into member-scoped services:

```
Digital ID  →  Member Hub  →  Representation · Help · Knowledge · Engagement · Verification
```

The card stays the same artifact; what changes is that it becomes a set of
member-scoped reads and writes. The strategic point: the card (a QR + a status)
is commodity and copyable. The **accumulated relational + temporal data** —
who represents whom, request history, continuity records — is not. That data is
the moat, and every feature below either produces it or consumes it.

---

## 2. Principles we inherit (do not re-invent)

This design must match the patterns already enforced in the repo:

1. **Tenant isolation is the security boundary, in the database.** Every table
   carries `tenant_id uuid NOT NULL REFERENCES public.tenants(id)`, has
   `ENABLE` + `FORCE ROW LEVEL SECURITY`, and policies scope rows to
   `public.get_request_tenant_id()` (the helper that reads `x-tenant-id`).
   See [0004_audit_log.sql](../supabase/migrations/0004_audit_log.sql).
2. **Anon never selects member data directly.** Direct anon `SELECT` on
   `members` was removed in migration 0008. Reads go through a
   `SECURITY DEFINER` RPC that re-derives the tenant from the request header
   (`lookup_member`, `record_verification`). New reads follow the same shape.
3. **History tables are append-only.** `SELECT`/`INSERT` policies only; no
   `UPDATE`/`DELETE`; `service_role` bypasses for forensic cleanup. This is how
   `verifications` and `audit_log` work, and it's exactly right for request
   history and continuity records.
4. **Pages are static, tenant-themed, and key off the UUID in the URL.**
   They resolve config via `resolveConfig()` ([lib/supabase.js](../lib/supabase.js)),
   fetch via RPC, and render with brand tokens (no shadows/gradients, 0.5px
   borders, reduced-motion support). [verify.html](../tenants/_template/verify.html)
   is the reference state machine.

---

## 3. Core data model — the representation spine

### 3.1 The decisive choice: assign to *positions*, not *people*

The continuity feature ("a steward retires, the member never loses access")
is not a UI feature — it is a consequence of one modeling decision:

> A member is assigned to a **position** (a seat, e.g. "Steward — Zone 3"),
> and a separate, time-bounded table records **which person holds that position**.

When a steward leaves, you close their `position_holders` row and open a new
one. Every member pointed at that position instantly sees the new rep, and the
full history of who held the seat is preserved. The naive shortcut
(member → person directly) breaks every link the day someone retires — which is
the exact problem the founder story is about. We pay a small modeling cost now
to make continuity automatic forever.

### 3.2 Tables (illustrative — not final SQL)

```
positions
  id            uuid pk
  tenant_id     uuid not null → tenants(id)
  kind          text not null   -- 'steward' | 'backup_steward' | 'unit_officer' | 'staff_rep'
  title         text not null   -- "Steward — Zone 3"
  work_area     text            -- "Nights · Warehouse B"
  created_at    timestamptz
  CHECK kind in ('steward','backup_steward','unit_officer','staff_rep')

representatives
  id            uuid pk
  tenant_id     uuid not null → tenants(id)
  full_name     text not null
  email         text
  phone         text
  photo_url     text            -- nullable; same "optional photo" stance as members
  user_id       uuid            -- nullable → auth.users(id) once reps log in (Phase 1+)
  created_at    timestamptz

position_holders            -- WHO fills a position, over time (the continuity table)
  id            uuid pk
  tenant_id     uuid not null → tenants(id)
  position_id   uuid not null → positions(id)
  rep_id        uuid not null → representatives(id)
  held_from     date not null
  held_to       date            -- NULL = currently held
  created_at    timestamptz
  -- "current holder" = held_to IS NULL; enforce at most one current per position

member_positions            -- WHICH position represents a member
  id            uuid pk
  tenant_id     uuid not null → tenants(id)
  member_id     uuid not null → members(id)
  position_id   uuid not null → positions(id)
  assigned_from date not null
  assigned_to   date            -- NULL = current assignment
  created_at    timestamptz
```

A member's **representation team** is then a query, not a stored blob:

```
member → member_positions (current)
       → positions
       → position_holders (current)
       → representatives
```

Grouping the resulting positions by `kind` gives the card's "My Steward /
Backup Steward / Unit Officer / Staff Rep" layout directly.

### 3.3 What "steward" is (resolving last turn's open question)

Last turn I couldn't tell whether "steward" meant the `members` table, a new
table, or the future `tenant_admins` role. Feature #1 answers it: a steward is a
**`representative`** (a person with contact info) **bound to a `position` that
represents a member**. It is *not* a member, and it is *not* (yet) a
`tenant_admins` row — though a rep who logs in to action help requests later
gets a `representatives.user_id` and possibly a `tenant_admins.role = 'steward'`
(the CHECK in [0006_tenant_admins.sql](../supabase/migrations/0006_tenant_admins.sql#L62)
already anticipates this).

---

## 4. RPCs (SECURITY DEFINER, tenant-scoped)

Mirrors `lookup_member`: re-derives tenant from the header, never trusts a
client-supplied `tenant_id`, returns only display fields.

- **`get_representation_team(p_member_id uuid)`** — the engine behind
  `/access/:uuid`. Walks the spine above and returns the current team:
  `[{ kind, title, work_area, full_name, email, phone, photo_url }]`. Returns
  an empty set if the member has no assignments (→ "not found" state). Filters
  to the request tenant internally; a UUID from another tenant returns empty.
- *(Phase 1)* **`submit_help_request(p_member_id, p_category, p_detail)`** —
  inserts a `help_requests` row, routes to the assigned position, returns the
  request id. Anon-writable via the RPC only (same posture as
  `record_verification`).
- *(Phase 1)* **`get_member_requests(p_member_id)`** — the request timeline.

No new `from('stewards').select()` anywhere — that path is closed by design.

---

## 5. Routing & the "My Steward" page

### 5.1 URL semantics

`/access/:uuid` where **`:uuid` is the member id** (the card already holds
`member.id`, so "My Steward" links to `/access/<member.id>`). The page shows
*that member's* representation team. This is consistent with card.html /
verify.html keying off the member UUID.

> Decision needed: confirm `:uuid` = member id (recommended), vs. a public
> per-steward profile page keyed by representative id. The roadmap below assumes
> member id.

### 5.2 Middleware change

[api/_middleware.js](../api/_middleware.js#L330) `resolveTenantTemplate()`
currently maps `access/<uuid>` → `/tenants/_template/access/<uuid>.html`
(nested, nonexistent → 404). Add a branch **before** the generic fallback:

```
if first segment is 'access' and second segment is a valid UUID:
    rewrite → /tenants/_template/access.html   (internal; browser URL stays /access/<uuid>)
```

Add `access` to the `TENANT_PAGES` set. Because Vercel rewrites are internal,
the visible URL remains `/access/<uuid>`, so the page reads the id straight from
`location.pathname` — no query-param juggling needed. (card/verify use `?id=`;
this path-param style is new but cleaner for a "front door" URL.)

### 5.3 Page: `tenants/_template/access.html`

Cloned from verify.html's structure and state machine:

- **Parse** the UUID from `location.pathname`; if it fails the UUID regex →
  render *not found* immediately, no fetch.
- **loading** → spinner ("Looking up your representation team…").
- **success** → render the team grouped by `kind`, each card with photo / name /
  work area / email / phone and a **Contact** action (`mailto:` / `tel:`).
- **empty** (RPC returns `[]`) → "No representative is assigned yet. Contact your
  local." — a real, non-error state for a member whose local hasn't mapped them.
- **error** (transport / RPC failure) → generic retry state; wrap the fetch in
  try/catch exactly like card.html.

### 5.4 Verification

Point [test_access.js](../test_access.js) at the running server and confirm
`200` + a rendered team. (Today it would hit its own 404 failure branch.)

---

## 6. Feature → data mapping & phased roadmap

The eight features are not peers — there's a dependency spine. Build order:

### Phase 0 — Representation spine  *(Feature #1: My Steward)*
`positions`, `representatives`, `position_holders`, `member_positions` +
`get_representation_team` + `/access/:uuid` + the page. **Everything else with a
"who represents me" dependency blocks on this.** This is the pending task from
last turn, correctly scoped.

### Phase 1 — Help routing + history  *(Features #2 "Need Help?" + #3 History)*
`help_requests` (status, category, member_id, position_id) and append-only
`help_request_events` (the "April 5 → Steward contacted → Resolved" timeline —
same shape as `verifications`/`audit_log`). Routing requires Phase 0 (you can't
route a request without knowing the assigned position). Reps need a way to
action requests → first real use of `representatives.user_id` + magic-link auth
([lib/supabase.js](../lib/supabase.js) already supports it).

### Phase 2 — Meeting & voting verification  *(Feature #6)*
Closest to what exists today: a branch off the verify.html scan flow + an
eligibility/attendance check and an append-only `attendance` table. **Largely
independent of the spine** — can run in parallel with Phase 1 if desired. Strong
standalone selling point.

### Phase 3 — Knowledge access  *(Features #4 CA search + #5 Benefits)*
Content + search, not relational PII. `documents` / `agreement_articles` +
`benefits`, plus an ingestion path and a search index. **No dependency on the
spine**; parallelizable. Main cost is content ingestion, not architecture.

### Phase 4 — Engagement  *(Feature #7)*
Derived analytics over events the earlier phases emit (verifications, help
requests, attendance, steward interactions). **Build the event emission early
and cheaply in each phase; build the dashboard last**, once there's data to show.
See the values caveat in §7.

---

## 7. Privacy, security & values constraints

These are not optional polish — they're load-bearing given the product's stated
positions (PIPEDA posture on [privacy.html](../app/privacy.html), the
member-trust framing on [about.html](../app/about.html)).

1. **"Need Help?" carries sensitive PII.** Harassment, accommodation,
   discipline, WSIB — among the most sensitive data a union holds. `help_requests`
   needs tenant-scoped RLS from day one, tight access (only the assigned rep +
   tenant admins, enforced in RLS, not the client), explicit retention, and an
   `audit_log` row on every read. Design this to the same bar as the rest of the
   schema before it ships, not after.
2. **The engagement dashboard is in tension with the brand's own values.** A
   screen ranking members "Highly Engaged / Disconnected" for executives is
   member surveillance — and About says *"Members aren't the customer"* and
   frames the audit log as a *member-trust* feature. Open product question, not a
   technical one: **who sees engagement data, and can members see their own?**
   Recommend: members see their own engagement; aggregate-only (not per-member
   leaderboards) for leadership, or an explicit, member-visible model. Flagging so
   it's a deliberate choice.

---

## 8. Naming (deferred, on purpose)

We standardized the whole site on **"The Union Hub Digital ID"** last session.
This direction proposes "Verified Union Identity" / "Union Membership Credential"
and dropping "AI-Native" (never actually used in the codebase). Recommendation:
**don't re-do the rename reactively.** The name should follow the product's
expanded role as the member's front door — lock the feature direction first, then
revisit naming once, deliberately, rather than churning copy twice.

---

## 9. Open decisions (need your input before Phase 0 build)

1. **`:uuid` = member id** (recommended) vs. per-steward profile keyed by rep id?
2. **Position taxonomy** — is `steward / backup_steward / unit_officer / staff_rep`
   the right starting set of `kind`s, or does your target local (e.g. Local 183)
   use different titles?
3. **One steward per member, or many?** The model supports many
   (member → multiple positions). Confirm the card should show a *team*, not a
   single steward.
4. **Rep contact data source** — entered by the tenant admin in the roster tool,
   or imported? (Affects whether Phase 0 needs an admin UI or just a seed path.)
5. **Engagement visibility** (§7.2) — member-visible vs. leadership-only vs.
   aggregate-only.

Once these are settled I can turn Phase 0 into a concrete migration + RPC + page
build.
