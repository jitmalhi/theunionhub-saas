-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub Access · Migration 0015 — stewards.role (credential tier)
-- ════════════════════════════════════════════════════════════════════════
-- Adds a queryable credential TIER to stewards, distinct from the existing
-- free-text `title`. The product now recognises three tiers of official
-- representative, in ascending scope:
--
--     'steward'       — shop / department steward            (default)
--     'unit_officer'  — unit officer
--     'executive'     — executive
--
-- Why a NEW column and not a reuse of `title`:
--   · `title` (migration 0013) is the human-facing POSITION string shown on
--     the scan page and used as the vCard TITLE — e.g. 'Chief Shop Steward',
--     'Plant 2 · Day Shift'. It is free-text and presentation-only.
--   · `role` is a CONSTRAINED, queryable tier the product reasons about: the
--     credential badge, roster filtering ("show all executives"), and any
--     future tier-gated capability. The two are orthogonal — an executive may
--     still carry a descriptive `title`.
--
-- Access / RLS:
--   · No new policy. `role` lives on the stewards row and is therefore covered
--     by the existing 0013 policies: anon (tenant-scoped) can READ it — the
--     tier is public, it IS the credential badge — and tenant admins manage it
--     through the same INSERT/UPDATE paths.
--   · ⚠ Self-edit escalation vector: 0013's stewards_admin_or_self_update lets
--     a linked steward UPDATE their own row (its WITH CHECK only pins tenant_id
--     + user_id), so the DATABASE does not, by itself, stop a steward from
--     setting their own role = 'executive'. Per the 0013 product decision,
--     field-level limits are enforced APP-SIDE: `role` MUST stay out of the
--     portal's EDITABLE set (it is — see
--     tenants/_template/access/portal/index.html). For a credential system a
--     DB-level guard is recommended as a fast-follow — see Known follow-ups.
--
-- Backfill: the column is added NOT NULL DEFAULT 'steward', so every existing
-- row becomes a 'steward' atomically. Promotion to unit_officer / executive is
-- an explicit admin action. There is deliberately NO automatic inference from
-- the free-text `title` — guessing a credential tier from a presentation
-- string risks mislabelling someone at exactly the moment trust matters. An
-- optional one-time inference snippet is provided in the notes for admins who
-- want a starting point.
--
-- Prerequisites: 0013 (stewards).
--
-- Idempotency: ADD COLUMN IF NOT EXISTS; the CHECK constraint and index are
-- added via guarded blocks (Postgres has no ADD CONSTRAINT IF NOT EXISTS).
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ─── 1 · role column ────────────────────────────────────────────────────
-- NOT NULL DEFAULT backfills every existing row to 'steward' in one shot.
ALTER TABLE public.stewards
  ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'steward';


-- ─── 2 · constrained vocabulary ─────────────────────────────────────────
-- Mirrors the stewards_status_known pattern (0013). Guarded on pg_constraint
-- because Postgres has no ADD CONSTRAINT IF NOT EXISTS — keeps re-runs clean.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.stewards'::regclass
       AND conname  = 'stewards_role_known'
  ) THEN
    ALTER TABLE public.stewards
      ADD CONSTRAINT stewards_role_known
      CHECK (role IN ('steward', 'unit_officer', 'executive'));
  END IF;
END $$;


-- ─── 3 · index for tier filtering ───────────────────────────────────────
-- Admin roster views filter by tier within a tenant ("all executives").
-- Composite (tenant_id, role) keeps it tenant-local, matching
-- stewards_tenant_status_idx (0013).
CREATE INDEX IF NOT EXISTS stewards_tenant_role_idx
  ON public.stewards (tenant_id, role);


-- ─── 4 · comment ────────────────────────────────────────────────────────
COMMENT ON COLUMN public.stewards.role IS
  'Credential TIER (constrained): steward | unit_officer | executive. '
  'Queryable and public — read by anon as the credential badge. Distinct from '
  'the free-text presentation `title`. Admin-managed; must stay OUT of the '
  'representative self-edit set (app-layer guard, per migration 0013).';


COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Column present, NOT NULL, defaulted:
--   SELECT column_name, data_type, is_nullable, column_default
--     FROM information_schema.columns
--    WHERE table_schema = 'public' AND table_name = 'stewards'
--      AND column_name = 'role';
--   -- Expect: text, NO, 'steward'::text.
--
--   -- CHECK constraint present:
--   SELECT conname, pg_get_constraintdef(oid)
--     FROM pg_constraint
--    WHERE conrelid = 'public.stewards'::regclass AND conname = 'stewards_role_known';
--   -- Expect: CHECK (role = ANY (ARRAY['steward','unit_officer','executive'])).
--
--   -- Index present:
--   SELECT indexname FROM pg_indexes
--    WHERE schemaname = 'public' AND tablename = 'stewards'
--      AND indexname = 'stewards_tenant_role_idx';
--
--   -- Bad value is rejected:
--   --   UPDATE public.stewards SET role = 'president' WHERE id = '…';
--   --   → ERROR: new row violates check constraint "stewards_role_known"
--
--   -- Tier filter (as anon, with x-tenant-id), via PostgREST:
--   --   curl -s "$SUPABASE_URL/rest/v1/stewards?select=full_name,role&role=eq.executive" \
--   --        -H "apikey: $SUPABASE_ANON_KEY" -H "x-tenant-id: $TENANT_UUID"
--
-- Optional ONE-TIME best-effort backfill from existing free-text `title`.
-- NOT run automatically (could mislabel). Run once in the SQL Editor, then
-- have an admin eyeball the results, if you want a head start over all-steward:
--
--   UPDATE public.stewards
--      SET role = CASE
--        WHEN title ~* '\m(exec|executive|president|vice.?president|treasurer|secretary)\M' THEN 'executive'
--        WHEN title ~* '\m(officer|chief|chair|chairperson|delegate)\M'                     THEN 'unit_officer'
--        ELSE role
--      END
--    WHERE role = 'steward';      -- only touch un-promoted rows
--
-- Known follow-ups (separate slices):
--   · 0016 (recommended for a credential system): a BEFORE UPDATE guard
--     trigger that blocks a non-admin (self-edit) from changing `role`, so the
--     escalation vector is closed at the DB, not only app-side. Shape:
--       IF NEW.role IS DISTINCT FROM OLD.role
--          AND NOT public.is_request_tenant_admin() THEN
--         RAISE EXCEPTION 'role_change_not_permitted';
--       END IF;
--   · Surface `role` in the fetch column lists + render a tier badge
--     (access.html, portal) and a tier control in the admin member editor.
--   · audit_log integration for role changes once stewards has audit hooks.
-- ════════════════════════════════════════════════════════════════════════
