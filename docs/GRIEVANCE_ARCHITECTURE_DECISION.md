# GRIEVANCE ARCHITECTURE DECISION

**Phase 4 · Reconcile the two grievance models** · 2026-07-16 · Branch `release/v0.1-production-hardening`
**Status:** DECIDED. Supersedes any ambiguity between `grievances` and `grievance_cases`.

---

## Decision

**`grievance_cases` (migration 0024) is the canonical, long-term grievance model. The legacy `grievances` (0017) is deprecated and will be migrated out.**

This is not a coin-flip — it's the model that carries the platform's vision (*"the system of record for what the Local knows"*). The legacy table cannot express that vision; the case model already does.

## The two models, compared (verified from schema)

| Capability | `grievances` (0017, **LIVE**) | `grievance_cases` (0024, **staged**) |
|---|---|---|
| Member linkage | `member_name` free text — **no relation** | `member_id` **FK → members** (referential integrity) |
| Case identity | none | `case_number`, unique per tenant |
| Lifecycle | 3 statuses (Open/In Progress/Resolved) | enum `INTAKE → STEP_1 → STEP_2 → STEP_3 → ARBITRATION → CLOSED` |
| Steward assignment | none | `assigned_to` FK → auth.users |
| CBA linkage | none | `contract_article` (+ `grievance_precedents`/`cba_articles`) |
| Dates | created/updated only | `date_incident`, `date_filed` |
| Deletion | hard delete | `deleted_at` **soft delete** |
| History / audit | none | **`grievance_history`, append-only, mutation-blocked, auto-logged on status change** |
| Deadlines | none | `grievance_deadlines` + `grievance_deadline_rules` (0026) |
| Notifications | none | `grievance_notifications` (0028) |
| Access model | admin-only | member (own) + admin, via `is_request_tenant_member`/`is_request_tenant_admin` |

`grievances` is a stub for "log a complaint." `grievance_cases` is a case-management system. There is no future in which the stub is the answer.

## Which tables hold valuable data
- **`grievances` (live):** may contain rows (demo/seed + any early real entries). Volume is currently near-zero (pre-customer), which makes migration cheap **now** — this is the right time to do it, before real data accumulates in the wrong table.
- **`grievance_cases` and its tier:** not yet applied → no data to preserve; pure additive apply.

## UI / code dependencies (must be handled, not ignored)
- **`lib/admin-grievances.js` reads the LEGACY `grievances` table** — this is the only live consumer. It must be **repointed** to `grievance_cases` as part of the merge. **Do not drop `grievances` until this repoint ships and is verified.**
- **`grievance-system` React SPA** targets the rich model (CBA browser, debrief form). Its consolidation (Phase 5) lands on `grievance_cases` — consistent with this decision.

## Data preservation & migration path (safe, ordered)
1. **Apply `0022–0030`** (additive; brings `grievance_cases` + history + deadlines + notifications + precedents + documents). No existing data touched. *(Live-execution phase — driven session.)*
2. **Backfill** legacy `grievances` → `grievance_cases` via a reviewed script:
   - `member_name` → resolve to a `members` row → `member_id`. **Wrinkle:** `grievance_cases.member_id` is `NOT NULL`. For unmatched legacy names, the migration must either (a) create/associate a member, or (b) temporarily allow a nullable `member_id` for backfilled rows behind a `legacy_member_name` column. **Recommended:** add a nullable `legacy_member_name text` column for provenance, match where possible, and require member linkage for all *new* cases.
   - `status` map: `Open`→`INTAKE`, `In Progress`→`STEP_1`, `Resolved`→`CLOSED`.
   - `grievance_type` → `description` prefix or a new `category` field (do not overload `contract_article`, which is a CBA reference).
   - Preserve `created_at`; generate `case_number` deterministically (e.g., `YYYY-####` per tenant).
3. **Repoint `lib/admin-grievances.js`** to `grievance_cases` (reads/writes, status enum, member linkage).
4. **Verify** — functional (admin can list/create/advance a case) + isolation (Phase 3 suite covers `grievance_cases`).
5. **Deprecate `grievances`** — rename to `grievances_legacy_archive` (read-only) for one release; **drop** in a later migration only after confirming zero unmigrated rows. Never drop in the same migration that backfills.

## Final grievance architecture (supports the vision)
`grievance_cases` as the hub, with:
- **Lifecycle** — status enum + transitions, logged automatically.
- **Assigned steward** — `assigned_to` (harden with steward-coverage routing later).
- **Deadlines** — `grievance_deadlines` + rules (auto-computed SLA clock).
- **Documents** — `documents` vault (Phase 6 storage RLS).
- **CBA references** — `contract_article` + `cba_articles` + `grievance_precedents`.
- **Resolution + audit history** — `grievance_history`, append-only, tenant-guarded.

**Identified gap (small, future):** no explicit **grievance ↔ meetings** linkage yet (the plan's target list mentions meetings). Add a lightweight `grievance_meetings` (or link to a future Meeting module) in v0.3 — not a v0.1 blocker.

## Risks
| Risk | Mitigation |
|---|---|
| `member_id NOT NULL` blocks legacy backfill | Add nullable `legacy_member_name`; match where possible |
| Dropping legacy too early loses data | Two-step: archive → verify empty → drop in a later migration |
| Admin UI breaks during repoint | Ship repoint + backfill together; verify before dropping legacy |
| `case_number` collisions on backfill | Deterministic per-tenant sequence; unique constraint already enforces safety |

**Bottom line:** adopt `grievance_cases`, migrate the (currently tiny) legacy data now while it's cheap, repoint the one live consumer, and retire `grievances` in two safe steps.
