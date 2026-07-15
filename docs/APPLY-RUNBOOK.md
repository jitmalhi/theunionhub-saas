# APPLY-RUNBOOK — live apply evening (migrations 0022–0040 + ai-service)

**One consolidated runbook for the live apply.** This is the gate for all further schema work (Phase 2 is held until every ✅ below passes on the live database).

- **Target project:** Supabase `frdvhmzbsmczknqtexvx` (now the `theunionhub.ca` primary entry in `lib/domains.js`; physical region **ca-central-1**). `theunionhub.com` is kept as a defensive alias pointing at the same project; its `us` label is only an env-namespace key, not the DB region.
- **Live host for verification:** `local183.theunionhub.ca` (demo/anchor tenant).
- **What applies:** `supabase/migrations/0022`–`0040` (grievance merge `0022`–`0030` + identity harvest `0032`–`0033` + Fable-review security fixes `0034` steward-PII lockdown / `0035` member_number auto-assign + **Tier-1 website product** `0036` site settings/hostnames / `0037` site content / `0038` get_public_site / `0039` export_site + **document pipeline** `0040` source_documents/document_extractions with the verify gate; `0031` is intentionally not present — reserved).
- **Risk profile:** additive, **zero data migration** (grievance never had live data; the identity harvest only ADDs a column + backfills + CREATE OR REPLACE; the website + pipeline migrations only CREATE new, initially-empty tables/RPCs/policies). The realistic rollback is *restore the pre-apply snapshot*, not per-statement undo.

> **Golden rule:** the steps are ordered and gated. **If any step fails, STOP — do not improvise fixes on the live DB. Go to §7 (Rollback).** DB migrations go through the CLI (`npx --no-install supabase db push`); the backup check is done in the **Dashboard** and the isolation tests in the **SQL Editor** (which runs as a role that can `SET ROLE`, as the tests require). No direct psql connection string is used.

### Tooling — Supabase CLI

The CLI is a **project-local dev dependency of `steward-system`** (`devDependencies.supabase`, currently `2.109.0`). The old global install under nvm was broken — its Windows platform binary `supabase.exe` was missing (`ENOENT`, only the `supabase-go.exe` half was present) — so it was removed.

**Two rules that prevent the failure that already bit us:**
1. **Run from `C:\X\steward-system`** — that's the only directory whose `node_modules` has the working CLI. Run from `C:\X` and npx finds nothing local.
2. **Always invoke as `npx --no-install supabase …`** — the `--no-install` flag forces the local copy and makes npx *refuse to silently download* a fresh (and possibly broken-binary) copy. Without it, npx-from-the-wrong-dir offers to install `supabase@2.109.0` into its cache and you can hit the same ENOENT.

Verify once (PowerShell shown; the machine's default shell):
```powershell
cd C:\X\steward-system                     # Git Bash: cd /c/X/steward-system
npx --no-install supabase --version        # must print a version, e.g. 2.109.0
```
If that ever prints ENOENT for `supabase.exe`, the binary was removed post-install — check Windows Defender → Protection history for a quarantined `supabase.exe`, then `npm install` again in `steward-system`.

Project ref `frdvhmzbsmczknqtexvx` is written literally where the CLI needs it. For the §4 verification curls, set the live host once (PowerShell — the machine's default shell):
```powershell
$env:LIVE_HOST = 'local183.theunionhub.ca'      # Git Bash: export LIVE_HOST=local183.theunionhub.ca
```
> No direct DB connection string is needed. The backup check runs in the Dashboard (§0) and the isolation tests run in the SQL Editor (§3). The CLI (`db push`, `migration list`) connects using the linked project + the DB password entered interactively at link time. The `npx --no-install supabase` and `curl` commands work in both PowerShell and Git Bash; the §4 curls use `$env:LIVE_HOST` (PowerShell) / `$LIVE_HOST` (Git Bash).

---

## 0 · Pre-flight — login, link, backup  ⏱️ ~10 min  *(do not skip)*

- [ ] **Log in + link the CLI** (terminal; enter the DB password when prompted — it is not stored in this repo):
  ```powershell
  cd C:\X\steward-system                          # Git Bash: cd /c/X/steward-system
  npx --no-install supabase login                 # opens browser / paste access token
  npx --no-install supabase link --project-ref frdvhmzbsmczknqtexvx
  npx --no-install supabase projects list         # confirms the project is linked
  ```
- [ ] **Backup floor — Dashboard** (no psql, no connection string): Supabase Dashboard → **Database → Backups**.
  - Confirm a **recent daily backup / PITR** point exists; if PITR is on, note the latest restore timestamp: `________ (UTC)`.
  - Trigger an **on-demand backup** if the button is available, so the restore floor is *immediately* pre-apply. **This backup is the rollback target in §7.**
- [ ] Confirm what's already applied so the push only adds `0022+`:
  ```bash
  npx --no-install supabase migration list        # remote should show 0001–0021 applied, 0022+ pending
  ```
  If remote already shows any `0022+`, STOP and reconcile before pushing.

### 0a · Repair the remote migration history if it's empty  *(only if `migration list` shows Remote blank for 0001–0021)*

**Why this can happen:** the live schema for `0001`–`0021` was applied historically via the **SQL Editor**, not the CLI. Those runs create the tables/RPCs but never write the `supabase_migrations.schema_migrations` history table the CLI reads. So `migration list` can show the **Remote column empty for every migration** even though the schema is fully live and production works. `db push` in that state would try to re-run `0001+` and fail on already-existing objects. The fix is to *tell the history table what's already applied* — a metadata-only repair, no schema SQL runs.

- [ ] **First prove the live schema really is at 0021** (don't repair blind). In **Dashboard → SQL Editor**, run both:
  ```sql
  -- A · 0001–0021 end-state present (expect every column non-null)
  select
    to_regclass('public.tenants')               as t_0001,
    to_regclass('public.members')               as t_0002,
    to_regclass('public.stewards')              as t_0013,
    to_regclass('public.grievances')            as t_0017,
    to_regclass('public.knowledge_entries')     as t_0018,
    to_regclass('public.member_interactions')   as t_0020,  -- newest table in 0001–0021
    to_regproc('public.lookup_member')          as fn_0008,
    to_regproc('public.workplace_intelligence') as fn_0021; -- newest RPC in 0001–0021
  ```
  ```sql
  -- B · remote is NOT already ahead into 0022+ (expect every column null, last = false)
  select
    to_regclass('public.steward_coverage')  as t_0022,
    to_regclass('public.grievance_cases')    as t_0024,
    to_regclass('public.documents')          as t_0029,
    to_regclass('public.ai_generations')     as t_0030,
    exists(select 1 from information_schema.columns
           where table_schema='public' and table_name='members'
             and column_name='member_number') as members_has_member_number_0032;
  ```
  If A is all non-null **and** B is all null/false, the live schema is exactly at 0021 → repair is safe. If B shows any object, the schema is beyond 0021 — STOP and reconcile which of `0022+` is actually live before touching history.
- [ ] **Mark only 0001–0021 as applied** (metadata write to the remote history; runs no migration SQL):
  ```powershell
  cd C:\X\steward-system
  npx --no-install supabase migration repair --status applied `
    0001 0002 0003 0004 0005 0006 0007 0008 0009 0010 0011 `
    0012 0013 0014 0015 0016 0017 0018 0019 0020 0021
  ```
  Older CLI builds take one version per call — fallback:
  ```powershell
  0001..0021 | ForEach-Object { npx --no-install supabase migration repair --status applied ('{0:0000}' -f $_) }
  ```
  Do **not** include `0022`–`0040` — they must stay pending so §1's `db push` adds them.
- [ ] Re-run `npx --no-install supabase migration list`. **Repair gate:** `0001`–`0021` now show in Remote, `0022`–`0040` do not, nothing else (`0031` is intentionally absent).

**Gate:** CLI linked, a pre-apply backup/PITR point is recorded from the Dashboard, and `migration list` shows `0001–0021` applied with only `0022+` pending (after the §0a repair if the history was empty). Do not proceed otherwise.

---

## 1 · Apply migrations 0022–0040  ⏱️ ~5 min

- [ ] Dry-run inspection (prints the SQL that will run, applies nothing):
  ```bash
  npx --no-install supabase db push --dry-run
  ```
  Confirm the list is exactly `0022 … 0030, 0032, 0033, 0034, 0035, 0036, 0037, 0038, 0039, 0040` (no `0031`, nothing unexpected).
- [ ] Apply:
  ```bash
  npx --no-install supabase db push
  ```
- [ ] Confirm all reported applied with no error; `npx --no-install supabase migration list` now shows `0040` as the latest applied.

**Gate:** `db push` exits 0 and `migration list` shows through `0040`. Any error → §7.

---

## 2 · Reload PostgREST schema cache  ⏱️ ~1 min

New tables/columns/RPCs (incl. `lookup_member`'s new `member_number` field, the `lookup_steward` RPC, the website RPCs `resolve_site_tenant` / `get_public_site` / `site_is_published` / `export_site`, and the `source_documents` / `document_extractions` pipeline tables) 404 over REST until the cache reloads. Run in **Dashboard → SQL Editor**:
```sql
NOTIFY pgrst, 'reload schema';
```
- [ ] Ran without error (SQL Editor shows "Success").

---

## 3 · Isolation test suites (all three must PASS)  ⏱️ ~4 min

Run each in **Dashboard → SQL Editor**. Each script is self-contained and ends in `ROLLBACK` — they leave no data behind. Open the file, copy its **full** contents into a new SQL Editor query, and Run.

- [ ] **Grievance tenant isolation** — `supabase/tests/grievance_tenant_isolation_test.sql` (D5 — header selects, DB authorizes).
  Expect the notice: `PASS: header selects the tenant, the database authorizes it. Cross-tenant header denied.`
- [ ] **Member verify isolation** — `supabase/tests/member_verify_isolation_test.sql` (direct-read denied + no cross-tenant resolve + member_number on the whitelisted shape).
  Expect the notice: `PASS: members direct-read denied (anon + non-admin); lookup_member is tenant-scoped; member_number exposed on the whitelisted shape only.`
- [ ] **Steward lookup isolation** — `supabase/tests/steward_lookup_isolation_test.sql` (0034: anon can't enumerate stewards; `lookup_steward` is tenant-scoped and returns only public fields).
  Expect the notice: `PASS: stewards direct-read denied to anon; lookup_steward is tenant-scoped and returns only public card fields.`
- [ ] **Document pipeline verify gate** — `supabase/tests/document_pipeline_isolation_test.sql` (0040: members read only `published` extractions, admins read all, cross-tenant denied, member writes blocked).
  Expect the notice: `PASS: verify gate holds — members read published only, admins read all, cross-tenant denied, member writes blocked.`

**Gate:** ALL FOUR show their `PASS:` notice with **no error**. In the SQL Editor a failed `ASSERT` surfaces as a query error (`ERROR: … FAIL: …`) instead of the notice — treat any error as a failed gate → §7. (The SQL Editor connects as a role that can `SET ROLE anon/authenticated`, which the tests require.)

---

## 4 · Live-behavior verification — existing flows intact  ⏱️ ~15 min

The merge must not have changed what already works. Verify against `$LIVE_HOST`.

**4a · Health / service-role writers configured**
- [ ] `curl -s https://$LIVE_HOST/api/health` → `200` with `ready:true` and `service_role_configured:true`.
  *(If `503`: the `SUPABASE_SERVICE_ROLE_KEY` env or redeploy is missing — see GO-LIVE §0. The service-role writers below will fail until this is `200`.)*

**4b · QR verification — all three outcomes** (open in a browser on `$LIVE_HOST`; the subdomain sets `x-tenant-id` automatically)
- [ ] **Verified** (active member): `https://$LIVE_HOST/verify?id=<ACTIVE_UUID>` → green "Verified.", name + Local, "Checked at …".
- [ ] **Not valid** (inactive/suspended member): `https://$LIVE_HOST/verify?id=<INACTIVE_OR_SUSPENDED_UUID>` → red "Not valid." with the lapsed/suspended copy.
- [ ] **Not found** (no such member): `https://$LIVE_HOST/verify?id=00000000-0000-0000-0000-000000000000` → black "Not found."
- [ ] Card side renders too: `https://$LIVE_HOST/card?id=<ACTIVE_UUID>` shows the **Member No.** row (backed by `0032`/`0033`) and the QR.

  > Pick the three UUIDs from real members in the `local183` tenant. If the demo trio was seeded on live they are: active `550bc413-53db-4f83-98e4-7c5c44d721d0`, inactive `21e63983-9b15-4cd6-99e4-179e28cd001e`, suspended `fd1be966-ca25-4e64-8a6a-d3402f1fdb58`. **Confirm they exist in this tenant first** (`select id,status from members where tenant_id = <local183-uuid>`); if not, use known live members instead. The not-found UUID is always the all-zeros one.

- [ ] Optional REST-level check of the RPC path (anon key + tenant header):
  ```bash
  curl -s -X POST "https://$SUPABASE_PROJECT_REF.supabase.co/rest/v1/rpc/lookup_member" \
    -H "apikey: $LIVE_ANON_KEY" -H "x-tenant-id: <local183-uuid>" \
    -H "Content-Type: application/json" -d '{"p_id":"<ACTIVE_UUID>"}'
  # → one row incl "member_number"; wrong tenant header → []
  ```

**4c · Public steward scan page (now RPC-backed — migration 0034)**
- [ ] Open a representative's public card `https://$LIVE_HOST/access/<steward-uuid>` → name, title, contact and **Save Contact** (vCard) still render. This now flows through `lookup_steward`; a blank/failed page means the RPC didn't reload (redo §2) or the id is wrong.
- [ ] Confirm anon can no longer dump the roster: the direct REST read must return `[]`:
  ```bash
  curl -s "https://$SUPABASE_PROJECT_REF.supabase.co/rest/v1/stewards?select=id,email" \
    -H "apikey: $LIVE_ANON_KEY" -H "x-tenant-id: <local183-uuid>"    # → []
  ```

**4d · Service-role writers (bypass RLS — the merge touched their tables' RLS)**
- [ ] **DFR / interaction writer** (`/api/log-interaction`): open `https://$LIVE_HOST/meet/a57e0a00-0000-4000-8000-000000000010` (seeded steward), complete the 3-step interaction → expect `201`, and a new row appears in `/admin/activity`.
- [ ] **Scan analytics** (`/api/access-event`): open a representative's `access.html` (scan/QR) → the per-profile view count increments (and **no** scanner-identifying data is written — schema-enforced).

**4e · Website tier — publish gate + render (migrations 0036–0039)**
- [ ] Publish the `local183` site: in **SQL Editor** `update public.site_settings set published = true where tenant_id = <local183-uuid>;` (or use the admin site editor), then `NOTIFY pgrst, 'reload schema';`.
- [ ] **DB-level (the real gate):** `select * from public.get_public_site('<local183-uuid>');` returns the site blob, and `select public.resolve_site_tenant('<a-local183-hostname>');` resolves the tenant. Flip `published=false` and confirm `get_public_site` no longer returns published content — **the publish gate holds** (unpublished tenants don't leak).
- [ ] **App-level (only if the site route is already deployed):** `curl -s https://$LIVE_HOST/api/site` (or open the apex/subdomain) renders the published page, not a 404.

**Gate:** health `200`, all three verify outcomes correct, both service-role writers land their rows, and the published `local183` site returns content via `get_public_site` while an unpublished tenant returns none. Any deviation → §7.

---

## 5 · Deploy ai-service  ⏱️ ~5 min

`ai_generations` (migration `0030`) is already applied in §1. The function itself deploys separately and safely refuses to generate until a key is set (HTTP 503 `ai_not_configured`) — no accidental spend.

- [ ] Deploy:
  ```bash
  npx --no-install supabase functions deploy ai-service
  ```
- [ ] (Optional, only when enabling AI) set the secret — **never** a `VITE_` var:
  ```bash
  npx --no-install supabase secrets set ANTHROPIC_API_KEY=sk-ant-xxxxxxxx
  # optional: npx --no-install supabase secrets set AI_MODEL=claude-opus-4-8
  ```
- [ ] Smoke: a call from the app returns "AI is not set up yet" (503) if no key, or generates if the key is set. No `sk-ant` / `anthropic` string in any client bundle (`grep -R "sk-ant" dist/ ; grep -Ri "anthropic" dist/` → nothing).

**Gate:** function deploys; with no key it 503s cleanly (does not error the app).

---

## 6 · Close-out

- [ ] Re-run `curl -s https://$LIVE_HOST/api/health` → still `200`.
- [ ] Record the apply in `docs/BACKLOG.md`: check off "Apply the merge (0022–0030) + website/pipeline (0036–0040) + deploy ai-service" in the rollout sequence.
- [ ] **Follow-up (code, not this evening):** bump `migration_version` in `api/health.js` from `'0021'` to `'0040'` and ship on the next normal deploy.
- [ ] Notify: the gate for Phase 2 (Identity System) and for the `0031` members-RLS-hardening deploy is now met. Phase 2 remains held until explicitly resumed.

---

## 7 · Rollback path  *(if ANY gate above fails)*

**Stop immediately. Do not hand-patch the live schema.** The changes are additive, so the fastest correct recovery is to restore the clean floor you captured in §0.

1. **Halt** — do not run later steps. Capture the exact failing command + full output.
2. **Assess blast radius:**
   - Failure in **§1 `db push`** → migrations are transactional per file; the failed file rolled back, but earlier files in the batch committed. Note the last file that shows in `supabase migration list`.
   - Failure in **§3 tests** → no data changed (tests `ROLLBACK`), but the schema from §1 is live and a guarantee is violated → treat as a real regression; do not leave it live.
   - Failure in **§4** → a live behavior regressed; do not leave it live.
3. **Restore (Dashboard):** Supabase Dashboard → **Database → Backups** → restore to the on-demand/PITR point recorded in §0. This reverts the whole DB to pre-apply. (No psql/logical restore — the Dashboard backup taken in §0 is the floor.)
4. **Re-verify** post-restore: run `NOTIFY pgrst, 'reload schema';` in the **SQL Editor**, then re-run §4a health + the three QR outcomes to confirm the *old* behavior is back.
5. **ai-service:** a deployed function is harmless without a key; if needed, redeploy the previous version or leave it (it 503s). Unset the key if one was set: `npx --no-install supabase secrets unset ANTHROPIC_API_KEY`.
6. **Do not retry the apply** until the failing migration/test is fixed **in the repo** and re-reviewed. The evening is over; reschedule.

---

_Prepared 2026-07-05; extended to `0022`–`0040` (Tier-1 website product + document pipeline) 2026-07-09. Execute this runbook to open the gate; nothing further (Phase 2, `0031`) proceeds until every gate here has passed live._
