-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0010 — per-tenant dues cycle
-- ════════════════════════════════════════════════════════════════════════
-- Generalises the "already collected" semantic from "same UTC day"
-- (hardcoded in 0004 via a GENERATED collection_date column) to
-- "same dues cycle," where a tenant picks daily / weekly / monthly /
-- quarterly.
--
-- The verify flow's idempotency story is:
--
--   When a verifier taps "Mark as paid" on a member, the system records
--   one dues_collections row for that (tenant, member, cycle_start).
--   A second tap inside the same cycle returns the existing row instead
--   of creating a duplicate — that's what powers verify.html's
--   "Already collected" screen.
--
-- Before this migration, "cycle" was always one UTC day. After this
-- migration, the cycle length is configurable per tenant.
--
-- Why the GENERATED column had to go
-- ─────────────────────────────────────────────────────────────────
-- collection_date was defined as `GENERATED ALWAYS AS (collected_at::date)
-- STORED` in 0004 — a perfect fit when every tenant uses UTC days but
-- impossible to extend to per-tenant cycles, because a GENERATED
-- expression can't subquery another table to look up the tenant's
-- cycle setting.
--
-- We DROP EXPRESSION to keep the column + its data but make it
-- explicitly writable. mark_member_paid now computes the cycle start
-- via the new tenant_cycle_start() helper and writes it into the
-- INSERT. The UNIQUE constraint on (tenant_id, member_id, collection_date)
-- still enforces one collection per cycle per member; what changed is
-- what "collection_date" means.
--
-- Backward-compat note: for tenants that change cycle mid-stream,
-- historical rows are NOT re-bucketed. A member who paid Monday under
-- a daily cycle has collection_date = '2026-05-19'; if the admin
-- switches to weekly on Tuesday, that member could be marked paid
-- again on Wednesday (which writes collection_date = '2026-05-18',
-- the Monday of that week — different from the historical Tuesday
-- row, so no UNIQUE violation). This is acceptable because cycle
-- changes are infrequent admin actions; the UI flags it in the
-- settings help text.
--
-- Prerequisites: 0001 (tenants), 0004 (dues_collections + verify RPCs),
--                0006 (is_tenant_admin), 0008 (the verify RPCs are
--                already SECURITY DEFINER).
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ─── 1 · Add tenants.dues_cycle ────────────────────────────────────────
-- Default 'daily' preserves prior behaviour for every existing tenant.

ALTER TABLE public.tenants
  ADD COLUMN IF NOT EXISTS dues_cycle text NOT NULL DEFAULT 'daily';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_schema    = 'public'
      AND table_name      = 'tenants'
      AND constraint_name = 'tenants_dues_cycle_known'
  ) THEN
    ALTER TABLE public.tenants
      ADD CONSTRAINT tenants_dues_cycle_known
      CHECK (dues_cycle IN ('daily', 'weekly', 'monthly', 'quarterly'));
  END IF;
END $$;

COMMENT ON COLUMN public.tenants.dues_cycle IS
  'How often the "already collected" check resets in the verify flow. '
  'One of daily | weekly | monthly | quarterly. Postgres week starts '
  'Monday per ISO 8601.';


-- ─── 2 · Drop the GENERATED expression on dues_collections.collection_date
-- The column + its existing values stay. New inserts must populate it
-- explicitly (which mark_member_paid does below).

ALTER TABLE public.dues_collections
  ALTER COLUMN collection_date DROP EXPRESSION IF EXISTS;

-- Rename the constraint to reflect the generalised semantic.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_schema    = 'public'
      AND table_name      = 'dues_collections'
      AND constraint_name = 'dues_one_per_member_per_day'
  ) THEN
    ALTER TABLE public.dues_collections
      RENAME CONSTRAINT dues_one_per_member_per_day TO dues_one_per_member_per_cycle;
  END IF;
END $$;

COMMENT ON COLUMN public.dues_collections.collection_date IS
  'Start date of the dues cycle this collection belongs to. Computed by '
  'mark_member_paid() via tenant_cycle_start(). Previously a GENERATED '
  'column (always = collected_at::date); promoted to a regular column '
  'in 0010 so cycles other than daily can be supported.';


-- ─── 3 · tenant_cycle_start(p_tenant_id, p_at) helper ──────────────────
-- Returns the start date of the dues cycle containing p_at, given the
-- tenant's dues_cycle setting. Used by mark_member_paid and
-- check_already_collected; could be called directly from admin UIs that
-- want to display "next cycle starts on…".

CREATE OR REPLACE FUNCTION public.tenant_cycle_start(
  p_tenant_id uuid,
  p_at        timestamptz DEFAULT NOW()
)
RETURNS date
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE COALESCE(
    (SELECT dues_cycle FROM public.tenants WHERE id = p_tenant_id),
    'daily'
  )
    WHEN 'daily'     THEN p_at::date
    WHEN 'weekly'    THEN date_trunc('week',    p_at)::date  -- Monday
    WHEN 'monthly'   THEN date_trunc('month',   p_at)::date
    WHEN 'quarterly' THEN date_trunc('quarter', p_at)::date
    ELSE p_at::date
  END;
$$;

REVOKE EXECUTE ON FUNCTION public.tenant_cycle_start(uuid, timestamptz) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.tenant_cycle_start(uuid, timestamptz) TO anon, authenticated;

COMMENT ON FUNCTION public.tenant_cycle_start(uuid, timestamptz) IS
  'Returns the start date of the dues cycle containing p_at for the given '
  'tenant. SECURITY DEFINER so it can read tenants.dues_cycle regardless '
  'of caller RLS. Granted to anon because the verify RPCs (also DEFINER) '
  'call it transitively.';


-- ─── 4 · mark_member_paid — replace literal current_date with the helper

CREATE OR REPLACE FUNCTION public.mark_member_paid(p_member_id uuid)
RETURNS TABLE (was_already_paid boolean, paid_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id    uuid;
  v_cycle_start  date;
  v_existing_at  timestamptz;
  v_new_at       timestamptz;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context'
      USING HINT = 'x-tenant-id header is missing or unresolvable';
  END IF;

  -- Member must exist in this tenant. RLS no longer scopes our SELECT
  -- (we're DEFINER post-0008), so the tenant_id filter is explicit.
  IF NOT EXISTS (
    SELECT 1 FROM public.members
     WHERE id = p_member_id AND tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'member_not_found_in_tenant'
      USING HINT = 'Member UUID does not exist in this tenant';
  END IF;

  v_cycle_start := public.tenant_cycle_start(v_tenant_id, NOW());

  SELECT collected_at INTO v_existing_at
    FROM public.dues_collections
   WHERE tenant_id       = v_tenant_id
     AND member_id       = p_member_id
     AND collection_date = v_cycle_start
   LIMIT 1;

  IF v_existing_at IS NOT NULL THEN
    RETURN QUERY SELECT true, v_existing_at;
    RETURN;
  END IF;

  -- Race-safe insert. Two verifiers tapping at the same instant both
  -- pass the pre-check; one wins the INSERT, the other catches
  -- unique_violation and re-reads the winning row. Both callers get a
  -- consistent answer. Same pattern as the original 0004 function.
  BEGIN
    INSERT INTO public.dues_collections (tenant_id, member_id, collection_date)
    VALUES (v_tenant_id, p_member_id, v_cycle_start)
    RETURNING collected_at INTO v_new_at;

    RETURN QUERY SELECT false, v_new_at;
  EXCEPTION WHEN unique_violation THEN
    SELECT collected_at INTO v_existing_at
      FROM public.dues_collections
     WHERE tenant_id       = v_tenant_id
       AND member_id       = p_member_id
       AND collection_date = v_cycle_start
     LIMIT 1;
    RETURN QUERY SELECT true, v_existing_at;
  END;
END;
$$;


-- ─── 5 · check_already_collected — same helper, same semantic ──────────

CREATE OR REPLACE FUNCTION public.check_already_collected(p_member_id uuid)
RETURNS TABLE (already boolean, paid_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id    uuid;
  v_cycle_start  date;
  v_collected_at timestamptz;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  v_cycle_start := public.tenant_cycle_start(v_tenant_id, NOW());

  SELECT collected_at INTO v_collected_at
    FROM public.dues_collections
   WHERE tenant_id       = v_tenant_id
     AND member_id       = p_member_id
     AND collection_date = v_cycle_start
   LIMIT 1;

  IF v_collected_at IS NOT NULL THEN
    RETURN QUERY SELECT true,  v_collected_at;
  ELSE
    RETURN QUERY SELECT false, NULL::timestamptz;
  END IF;
END;
$$;


-- ─── 6 · update_tenant_settings — add p_dues_cycle parameter ───────────
-- New signature has 5 params (was 4). Drop the old function first
-- because Postgres treats different parameter lists as overloads;
-- PostgREST resolves by name, but two overloads make logs noisier
-- without buying anything.

DROP FUNCTION IF EXISTS public.update_tenant_settings(text, text, text, text);

CREATE OR REPLACE FUNCTION public.update_tenant_settings(
  p_display_name text DEFAULT NULL,
  p_accent_hex   text DEFAULT NULL,
  p_local_number text DEFAULT NULL,
  p_union_type   text DEFAULT NULL,
  p_dues_cycle   text DEFAULT NULL
)
RETURNS public.tenants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id   uuid;
  v_user_id     uuid;
  v_user_email  text;
  v_cycle       text;
  v_result      public.tenants%ROWTYPE;
  v_changed     jsonb;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context'
      USING HINT = 'x-tenant-id header is missing';
  END IF;

  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated'
      USING HINT = 'Settings updates require a signed-in user';
  END IF;

  IF NOT public.is_tenant_admin(v_tenant_id, v_user_id) THEN
    RAISE EXCEPTION 'not_tenant_admin'
      USING HINT = 'You are not an admin of this tenant';
  END IF;

  -- Validate dues_cycle explicitly so the UI sees a clean code
  -- (invalid_dues_cycle) rather than the raw CHECK violation.
  v_cycle := NULLIF(trim(p_dues_cycle), '');
  IF v_cycle IS NOT NULL
     AND v_cycle NOT IN ('daily','weekly','monthly','quarterly') THEN
    RAISE EXCEPTION 'invalid_dues_cycle'
      USING HINT = 'Allowed values: daily, weekly, monthly, quarterly';
  END IF;

  UPDATE public.tenants
     SET display_name = COALESCE(NULLIF(trim(p_display_name), ''), display_name),
         accent_hex   = COALESCE(NULLIF(trim(p_accent_hex),   ''), accent_hex),
         local_number = COALESCE(NULLIF(trim(p_local_number), ''), local_number),
         union_type   = COALESCE(NULLIF(trim(p_union_type),   ''), union_type),
         dues_cycle   = COALESCE(v_cycle, dues_cycle),
         updated_at   = NOW()
   WHERE id = v_tenant_id
   RETURNING * INTO v_result;

  v_changed := jsonb_strip_nulls(jsonb_build_object(
    'display_name', p_display_name,
    'accent_hex',   p_accent_hex,
    'local_number', p_local_number,
    'union_type',   p_union_type,
    'dues_cycle',   p_dues_cycle
  ));

  SELECT email INTO v_user_email FROM auth.users WHERE id = v_user_id;

  INSERT INTO public.audit_log (
    tenant_id, actor, action, target_type, target_id, detail
  )
  VALUES (
    v_tenant_id,
    'user:' || v_user_id::text,
    'tenant_settings_updated',
    'tenant',
    v_tenant_id,
    jsonb_build_object('actor_email', v_user_email, 'changed', v_changed)
  );

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.update_tenant_settings(text, text, text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.update_tenant_settings(text, text, text, text, text) TO authenticated;

COMMENT ON FUNCTION public.update_tenant_settings(text, text, text, text, text) IS
  'Admin-only mutation of tenant display + cycle fields. Same exception '
  'codes as the 4-arg signature this replaces, plus invalid_dues_cycle '
  'when p_dues_cycle is non-NULL and outside the allowed set.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Schema:
--   \d public.tenants
--   -- Expect: dues_cycle text NOT NULL DEFAULT 'daily' with CHECK
--
--   \d public.dues_collections
--   -- Expect: collection_date date (no GENERATED expression)
--   -- Expect: constraint renamed to dues_one_per_member_per_cycle
--
--   -- Switch a tenant to weekly:
--   SELECT * FROM public.update_tenant_settings(
--     p_dues_cycle => 'weekly'
--   );
--   -- (Requires an admin session; see settings.html for the UI path.)
--
--   -- Inspect what the cycle start resolves to for the demo tenant:
--   SELECT public.tenant_cycle_start(
--     (SELECT id FROM public.tenants WHERE slug='demo'),
--     NOW()
--   );
--   -- daily   → today's date
--   -- weekly  → Monday of this week
--   -- monthly → first of this month
--   -- quarterly → first day of this quarter (Jan/Apr/Jul/Oct 1)
--
--   -- The verify flow still works; mark_member_paid produces the
--   -- same response shape, just with a cycle-aware idempotency window:
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/mark_member_paid" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Content-Type: application/json" \
--        -d '{"p_member_id":"550bc413-53db-4f83-98e4-7c5c44d721d0"}'
--
-- Known follow-ups (deferred):
--   · Sunday-start weeks for tenants that use that calendar — today
--     we use Postgres' ISO 8601 default (Monday).
--   · Custom cycle anchors (e.g. fiscal year starting in July) —
--     today quarterly always means calendar quarter.
--   · Cycle-change warning UI in settings.html: "Switching from
--     daily to weekly may bill members who paid in the last 6 days
--     a second time this week." Today this is documented in the
--     settings help text but not flagged as an interactive warning.
-- ════════════════════════════════════════════════════════════════════════
