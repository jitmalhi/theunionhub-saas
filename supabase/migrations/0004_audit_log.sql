-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0004 — verifications + dues_collections +
--                                 audit_log + the three RPCs verify.html
--                                 already calls
-- ════════════════════════════════════════════════════════════════════════
-- Lands the "member trust" feature surface. The about.html copy states
-- this is a member-trust feature, not a compliance feature:
--
--   "If we can't tell a member who looked at their record, when, and
--    what they saw, we don't deserve to hold the record."
--
-- This migration creates three concerns as three tables:
--
--   1. verifications   — every QR scan recorded. Append-only, high
--                        volume, anon-writable via record_verification().
--                        Answers "who looked at your record, when, and
--                        what they saw."
--
--   2. dues_collections — one row per (member, day). UNIQUE constraint
--                        + ON CONFLICT in mark_member_paid() makes the
--                        "already collected today" semantic correct
--                        under concurrent scans by multiple verifiers.
--
--   3. audit_log       — low-volume system events: tenant created /
--                        archived, admin actions, schema-driving things.
--                        Where scripts/new-tenant.mjs writes its row 0.
--                        NOT a scan log — that's verifications.
--
-- And the three RPCs verify.html has been calling since the prototype
-- but which until now have 404'd silently:
--
--   record_verification(p_member_id uuid, p_result text)         → void
--   check_already_collected(p_member_id uuid)                    → (already, paid_at)
--   mark_member_paid(p_member_id uuid)                           → (was_already_paid, paid_at)
--
-- All three are SECURITY INVOKER and respect RLS — there is no need
-- for a SECURITY DEFINER escape hatch here because every operation is
-- tenant-scoped and the caller's anon/authenticated role already has
-- the right grants. Race conditions on mark_member_paid (two verifiers
-- scan the same member at the same instant) are handled by the UNIQUE
-- constraint + EXCEPTION block, not by SERIALIZABLE isolation.
--
-- Prerequisites: 0001 (tenants), 0002 (members.tenant_id +
--               get_request_tenant_id()).
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


/* ════════════════════════════════════════════════════════════════════════
   1 · audit_log
   ════════════════════════════════════════════════════════════════════════
   Low-volume system event log. One row per meaningful tenant-level event.

   Distinct from verifications: verifications records every scan (high
   volume, anon-writable). audit_log records lifecycle events (low volume,
   system or admin-writable).

   Anon CANNOT read or write audit_log. Only authenticated users (admin
   tools) and the service role (provisioning script) touch it.

   The detail jsonb column is the schema's escape hatch: structured but
   not schemaful. Use it for context that wouldn't justify a column of
   its own (e.g. {"old_status": "pending", "new_status": "active",
   "provisioned_by": "scripts/new-tenant.mjs"}).
   ════════════════════════════════════════════════════════════════════════ */

CREATE TABLE IF NOT EXISTS public.audit_log (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,
  actor        text        NOT NULL,                  -- 'system:new-tenant.mjs', 'user:<uuid>', 'anon'
  action       text        NOT NULL,                  -- 'tenant_created', 'status_changed', …
  target_type  text,                                  -- 'tenant', 'member', 'verification'
  target_id    uuid,                                  -- the row the action acted on
  detail       jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT NOW(),

  CONSTRAINT audit_log_actor_not_blank  CHECK (length(trim(actor))  > 0),
  CONSTRAINT audit_log_action_not_blank CHECK (length(trim(action)) > 0)
);

CREATE INDEX IF NOT EXISTS audit_log_tenant_created_idx
  ON public.audit_log (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS audit_log_target_idx
  ON public.audit_log (target_type, target_id, created_at DESC);

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS audit_log_authenticated_read ON public.audit_log;
CREATE POLICY audit_log_authenticated_read
  ON public.audit_log
  FOR SELECT
  TO authenticated
  USING (tenant_id = public.get_request_tenant_id());

-- No anon policies. No INSERT/UPDATE/DELETE policies. Only service_role
-- writes (bypasses RLS); anon cannot read or write at all.


/* ════════════════════════════════════════════════════════════════════════
   2 · verifications
   ════════════════════════════════════════════════════════════════════════
   Append-only log of every QR scan. The data that backs the "who looked
   at your record" promise. Written by verify.html via record_verification().

   Anon CAN write (verifiers don't sign in) — but only via the RPC, which
   re-derives tenant_id from the request header rather than trusting it
   as a column value in the INSERT.

   Anon CAN read (so the verify page or a future "recent scans" widget
   works without auth), but only rows for their current tenant.
   ════════════════════════════════════════════════════════════════════════ */

CREATE TABLE IF NOT EXISTS public.verifications (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,
  member_id    uuid        NOT NULL REFERENCES public.members(id) ON DELETE RESTRICT,
  result       text        NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT NOW(),

  -- Mirrors verify.html's setResult() vocabulary. Update both in lockstep.
  CONSTRAINT verifications_result_known
    CHECK (result IN ('verified', 'invalid', 'notfound', 'already_collected'))
);

CREATE INDEX IF NOT EXISTS verifications_tenant_created_idx
  ON public.verifications (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS verifications_member_created_idx
  ON public.verifications (tenant_id, member_id, created_at DESC);

ALTER TABLE public.verifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.verifications FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS verifications_tenant_isolated_read ON public.verifications;
CREATE POLICY verifications_tenant_isolated_read
  ON public.verifications
  FOR SELECT
  TO anon, authenticated
  USING (tenant_id = public.get_request_tenant_id());

DROP POLICY IF EXISTS verifications_tenant_isolated_insert ON public.verifications;
CREATE POLICY verifications_tenant_isolated_insert
  ON public.verifications
  FOR INSERT
  TO anon, authenticated
  WITH CHECK (tenant_id = public.get_request_tenant_id());

-- No UPDATE / DELETE policies. verifications is append-only: rewriting
-- history undermines the entire trust feature. service_role bypasses,
-- of course, for the rare cleanup case (e.g. delete obviously-bad rows
-- in a forensic incident).


/* ════════════════════════════════════════════════════════════════════════
   3 · dues_collections
   ════════════════════════════════════════════════════════════════════════
   One row per (tenant, member, calendar day). The UNIQUE constraint on
   collection_date is what gives mark_member_paid() its "already
   collected" answer even under concurrent scans.

   collection_date is a GENERATED column derived from collected_at in
   UTC, so the constraint and the indexes derive from the actual
   collection time automatically. Must be expressed as
   `(collected_at AT TIME ZONE 'UTC')::date` rather than
   `collected_at::date` — the latter is STABLE (depends on session
   TimeZone) and PostgreSQL rejects it from GENERATED expressions
   with 42P17 "generation expression is not immutable". Anchoring on
   UTC is intentional anyway: locals operating across timezone
   boundaries should not see different cycle boundaries based on the
   verifier's browser locale.
   ════════════════════════════════════════════════════════════════════════ */

CREATE TABLE IF NOT EXISTS public.dues_collections (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,
  member_id       uuid        NOT NULL REFERENCES public.members(id) ON DELETE RESTRICT,
  collected_at    timestamptz NOT NULL DEFAULT NOW(),
  collected_by    uuid,                              -- auth.users(id) when known; nullable for anon
  collection_date date        GENERATED ALWAYS AS ((collected_at AT TIME ZONE 'UTC')::date) STORED,
  notes           text,

  CONSTRAINT dues_one_per_member_per_day
    UNIQUE (tenant_id, member_id, collection_date)
);

CREATE INDEX IF NOT EXISTS dues_collections_tenant_date_idx
  ON public.dues_collections (tenant_id, collection_date DESC);

ALTER TABLE public.dues_collections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dues_collections FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dues_tenant_isolated_read ON public.dues_collections;
CREATE POLICY dues_tenant_isolated_read
  ON public.dues_collections
  FOR SELECT
  TO anon, authenticated
  USING (tenant_id = public.get_request_tenant_id());

DROP POLICY IF EXISTS dues_tenant_isolated_insert ON public.dues_collections;
CREATE POLICY dues_tenant_isolated_insert
  ON public.dues_collections
  FOR INSERT
  TO anon, authenticated
  WITH CHECK (tenant_id = public.get_request_tenant_id());

-- No UPDATE / DELETE for non-service-role. Payments don't get edited
-- after the fact; corrections are new rows the admin app annotates with
-- notes referencing the original.


/* ════════════════════════════════════════════════════════════════════════
   4 · RPC — record_verification
   ════════════════════════════════════════════════════════════════════════
   Fire-and-forget log of a verification attempt. verify.html calls this
   with .keepalive so it survives the user navigating away mid-render.

   SECURITY INVOKER so the verifications RLS policy applies — anon must
   carry x-tenant-id (the middleware sets it; lib/tenant.js → currentTenant
   → sbHeaders threads it). Without the header, get_request_tenant_id()
   returns NULL, the INSERT WITH CHECK fails, the function silently
   returns. The caller never sees the failure (intentional — we don't
   want a logging failure to break the verify UX).
   ════════════════════════════════════════════════════════════════════════ */

CREATE OR REPLACE FUNCTION public.record_verification(
  p_member_id uuid,
  p_result    text
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RETURN;                                          -- no tenant context → silent no-op
  END IF;

  -- Cheap existence check using the RLS-filtered view of members. If
  -- the member isn't visible (wrong tenant, fake UUID, deleted), we
  -- skip the insert rather than write a row that references nothing
  -- useful. The FK would catch it too, but the explicit return keeps
  -- the function quiet for the caller.
  IF NOT EXISTS (SELECT 1 FROM public.members WHERE id = p_member_id) THEN
    RETURN;
  END IF;

  BEGIN
    INSERT INTO public.verifications (tenant_id, member_id, result)
    VALUES (v_tenant_id, p_member_id, p_result);
  EXCEPTION WHEN OTHERS THEN
    -- Logging must never break the verify flow. Swallow anything the
    -- INSERT raises (RLS rejection, CHECK violation on bad result
    -- value, etc.) — the verify page is already committed to its
    -- response by the time this RPC fires.
    NULL;
  END;
END;
$$;


/* ════════════════════════════════════════════════════════════════════════
   5 · RPC — check_already_collected
   ════════════════════════════════════════════════════════════════════════
   "Has this member's dues been collected today?" verify.html calls this
   right after fetching the member; if already=true, it skips the
   verified screen and shows the "Already collected" screen with the
   timestamp the dues were taken.

   STABLE so PostgreSQL can cache the result within a query if needed,
   and so PostgREST exposes it via GET (verify.html sends POST anyway;
   either works).
   ════════════════════════════════════════════════════════════════════════ */

CREATE OR REPLACE FUNCTION public.check_already_collected(p_member_id uuid)
RETURNS TABLE (already boolean, paid_at timestamptz)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
STABLE
AS $$
DECLARE
  v_collected_at timestamptz;
BEGIN
  SELECT collected_at INTO v_collected_at
    FROM public.dues_collections
   WHERE tenant_id       = public.get_request_tenant_id()
     AND member_id       = p_member_id
     AND collection_date = current_date
   LIMIT 1;

  IF v_collected_at IS NOT NULL THEN
    RETURN QUERY SELECT true,  v_collected_at;
  ELSE
    RETURN QUERY SELECT false, NULL::timestamptz;
  END IF;
END;
$$;


/* ════════════════════════════════════════════════════════════════════════
   6 · RPC — mark_member_paid
   ════════════════════════════════════════════════════════════════════════
   Idempotent: calling twice in the same day for the same member returns
   the original collected_at the second time, not a new one.

   Race-safe: two verifiers tapping "Mark as paid" at the same instant
   both pass the pre-check, both try to INSERT, one succeeds, the other
   catches unique_violation and re-reads the winning row. Either way,
   both callers get a consistent answer.

   Failure modes that DO raise:
     · Member not visible in current tenant → 'member_not_found_in_tenant'
     · No tenant context (header missing)   → 'no_tenant_context'
   verify.html's catch block surfaces both as "Couldn't mark paid — tap
   to retry," which is the correct UX for a verifier hitting a
   transient or misconfigured state.
   ════════════════════════════════════════════════════════════════════════ */

CREATE OR REPLACE FUNCTION public.mark_member_paid(p_member_id uuid)
RETURNS TABLE (was_already_paid boolean, paid_at timestamptz)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id    uuid;
  v_existing_at  timestamptz;
  v_new_at       timestamptz;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context'
      USING HINT = 'x-tenant-id header is missing or unresolvable';
  END IF;

  -- Member must be visible to the current tenant. RLS on members
  -- already filters, so this query returns the row only when the
  -- member belongs to the tenant in the header.
  IF NOT EXISTS (SELECT 1 FROM public.members WHERE id = p_member_id) THEN
    RAISE EXCEPTION 'member_not_found_in_tenant'
      USING HINT = 'Member UUID does not exist in this tenant';
  END IF;

  -- Pre-check the common case (already collected today).
  SELECT collected_at INTO v_existing_at
    FROM public.dues_collections
   WHERE tenant_id       = v_tenant_id
     AND member_id       = p_member_id
     AND collection_date = current_date
   LIMIT 1;

  IF v_existing_at IS NOT NULL THEN
    RETURN QUERY SELECT true, v_existing_at;
    RETURN;
  END IF;

  -- Attempt insert. If two verifiers tap simultaneously and both make
  -- it past the pre-check, exactly one wins this INSERT and the other
  -- catches unique_violation, then re-reads the winning row.
  BEGIN
    INSERT INTO public.dues_collections (tenant_id, member_id)
    VALUES (v_tenant_id, p_member_id)
    RETURNING collected_at INTO v_new_at;

    RETURN QUERY SELECT false, v_new_at;
  EXCEPTION WHEN unique_violation THEN
    SELECT collected_at INTO v_existing_at
      FROM public.dues_collections
     WHERE tenant_id       = v_tenant_id
       AND member_id       = p_member_id
       AND collection_date = current_date
     LIMIT 1;
    RETURN QUERY SELECT true, v_existing_at;
  END;
END;
$$;


/* ════════════════════════════════════════════════════════════════════════
   7 · GRANTS — lock down the default PUBLIC grant, open to anon + auth
   ════════════════════════════════════════════════════════════════════════ */

REVOKE EXECUTE ON FUNCTION public.record_verification(uuid, text)    FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.check_already_collected(uuid)      FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_member_paid(uuid)             FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.record_verification(uuid, text)     TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_already_collected(uuid)       TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_member_paid(uuid)              TO anon, authenticated;


/* ════════════════════════════════════════════════════════════════════════
   8 · COMMENTS
   ════════════════════════════════════════════════════════════════════════ */

COMMENT ON TABLE  public.audit_log       IS 'System-level lifecycle events. Low volume, auth-only read, system-only write.';
COMMENT ON COLUMN public.audit_log.actor IS 'Identity string: ''system:<script>'', ''user:<uuid>'', or ''anon''.';
COMMENT ON COLUMN public.audit_log.detail IS 'Free-form structured context. Document key conventions in the admin tools README.';

COMMENT ON TABLE  public.verifications        IS 'Append-only QR scan log. The data behind the "who looked at your record" promise.';
COMMENT ON COLUMN public.verifications.result IS 'verified | invalid | notfound | already_collected. Mirror of verify.html setResult vocabulary.';

COMMENT ON TABLE  public.dues_collections                  IS 'One row per (tenant, member, day). UNIQUE collection_date enforces idempotency.';
COMMENT ON COLUMN public.dues_collections.collection_date  IS 'GENERATED from collected_at::date. The dedup key for mark_member_paid race-safety.';

COMMENT ON FUNCTION public.record_verification(uuid, text)
  IS 'Fire-and-forget scan log insert. Silent no-op on any failure (no tenant, missing member, RLS rejection) so the verify UX is never blocked by logging.';

COMMENT ON FUNCTION public.check_already_collected(uuid)
  IS 'Returns (already, paid_at) for a member''s dues collection state TODAY in the current tenant.';

COMMENT ON FUNCTION public.mark_member_paid(uuid)
  IS 'Idempotent + race-safe. Returns (was_already_paid, paid_at). Raises member_not_found_in_tenant or no_tenant_context on misconfiguration.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Tables exist with RLS on:
--   SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class
--    WHERE relname IN ('verifications','dues_collections','audit_log');
--   -- Expect three rows, all (t, t).
--
--   -- The three RPCs are exposed via PostgREST:
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/check_already_collected" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Content-Type: application/json" \
--        -d '{"p_member_id":"550bc413-53db-4f83-98e4-7c5c44d721d0"}'
--   -- Expect: [{"already":false,"paid_at":null}]
--
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/mark_member_paid" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Content-Type: application/json" \
--        -d '{"p_member_id":"550bc413-53db-4f83-98e4-7c5c44d721d0"}'
--   -- First call: [{"was_already_paid":false,"paid_at":"2026-…"}]
--   -- Second call (same day): [{"was_already_paid":true,"paid_at":"<same>"}]
--
--   -- Cross-tenant denial (no x-tenant-id at all):
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/mark_member_paid" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "Content-Type: application/json" \
--        -d '{"p_member_id":"550bc413-53db-4f83-98e4-7c5c44d721d0"}'
--   -- Expect: 4xx with code no_tenant_context
--
--   -- verifications RLS sanity:
--   SELECT count(*) FROM public.verifications;   -- as anon via PostgREST with
--                                                -- right x-tenant-id → returns
--                                                -- only that tenant's rows
--
-- Knock-on effects (already wired, no code change needed):
--
--   · scripts/new-tenant.mjs → sbSeedAuditRow now SUCCEEDS instead of
--     skipping. The "audit_log table doesn't exist yet" notice goes away.
--     Every new tenant gets a row 0 written at provisioning time.
--
--   · public_stats() (migration 0003) starts returning a non-zero
--     verifications_today as soon as verify.html records its first
--     scan today. The defensive EXCEPTION WHEN undefined_table in
--     that function stops firing — no edit needed there.
--
--   · verify.html's three /rest/v1/rpc/* calls stop 404ing and start
--     doing what their names say. The "Mark as paid" button in demo
--     mode still uses its setTimeout simulation, but the live ?id=…
--     flow now does the real INSERT under RLS.
--
-- Known follow-ups (separate migrations / commits):
--   · Per-tenant dues cycle config (weekly, monthly, fiscal-quarter) —
--     today the collection_date is hardcoded to UTC date.
--   · Verifier identity capture — currently dues_collections.collected_by
--     stays NULL because verify.html runs as anon. Once the admin-side
--     "verify as signed-in steward" flow ships, capture auth.uid() in
--     mark_member_paid and stamp it into the row.
-- ════════════════════════════════════════════════════════════════════════
