-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub Access · Migration 0020 — member_interactions (DFR log)
-- ════════════════════════════════════════════════════════════════════════
-- An auditable, time-stamped record of a member↔steward representation
-- meeting, logged when a member scans the steward's QR and confirms the
-- interaction. This is the Duty of Fair Representation (DFR) defense: a neutral
-- record that protects both the member and the steward.
--
-- Write model (mirrors steward_analytics, 0013):
--   The member is ANONYMOUS (not signed in). There is NO anon/authenticated
--   INSERT policy — rows are written ONLY by the server-side API route
--   (api/log-interaction.js) using the service_role key, which bypasses RLS.
--   That makes the log un-forgeable from the browser: a fake entry would need
--   the secret service-role key, which never reaches the client.
--
-- Read model:
--   Admins read all interactions in their tenant; a steward reads their own
--   (derived through stewards, which carries tenant_id + user_id). Append-only:
--   no UPDATE/DELETE policy (immutable record; service role handles retention).
--
-- Conventions: tenant_id NOT NULL → tenants (RESTRICT); FK → stewards (CASCADE);
-- ENABLE + FORCE RLS; no updated_at (immutable).
--
-- Prerequisites: 0001 (tenants), 0002 (get_request_tenant_id),
--                0008 (is_request_tenant_admin), 0013 (stewards).
-- Idempotency: IF NOT EXISTS / DROP … IF EXISTS. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE IF NOT EXISTS public.member_interactions (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  tenant_id     uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,
  steward_id    uuid        NOT NULL REFERENCES public.stewards(id) ON DELETE CASCADE,

  -- "Are you currently with [Steward] discussing a workplace concern?"
  confirmed     boolean     NOT NULL DEFAULT false,
  -- Topic dropdown.
  topic         text,
  -- "I understand [Steward] has explained the next steps…"
  understood_next_steps boolean NOT NULL DEFAULT false,

  device_type   text,                                  -- mobile | tablet | desktop
  created_at    timestamptz NOT NULL DEFAULT NOW(),

  CONSTRAINT member_interactions_topic_known
    CHECK (topic IS NULL OR topic IN
      ('Grievance', 'Health & Safety', 'General Inquiry', 'Discipline', 'Scheduling', 'Other'))
);

CREATE INDEX IF NOT EXISTS member_interactions_tenant_idx  ON public.member_interactions (tenant_id);
CREATE INDEX IF NOT EXISTS member_interactions_steward_idx ON public.member_interactions (steward_id);
CREATE INDEX IF NOT EXISTS member_interactions_created_idx ON public.member_interactions (created_at DESC);

ALTER TABLE public.member_interactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_interactions FORCE  ROW LEVEL SECURITY;

-- No INSERT policy: server-side service_role only (see header).

-- SELECT — admins read all in their tenant; a steward reads interactions on
-- their own QR. Derived via stewards (this table has no user_id of its own).
DROP POLICY IF EXISTS member_interactions_admin_or_self_read ON public.member_interactions;
CREATE POLICY member_interactions_admin_or_self_read
  ON public.member_interactions
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.stewards s
       WHERE s.id        = member_interactions.steward_id
         AND s.tenant_id = public.get_request_tenant_id()
         AND (public.is_request_tenant_admin() OR s.user_id = auth.uid())
    )
  );

-- No UPDATE/DELETE policies — append-only for everyone but the service role.

COMMENT ON TABLE  public.member_interactions IS 'Auditable member↔steward representation-meeting log (DFR defense). Written server-side (service_role) only; admins read all-in-tenant, stewards read their own. Append-only.';
COMMENT ON COLUMN public.member_interactions.confirmed             IS 'Member confirmed they are meeting the steward about a workplace concern.';
COMMENT ON COLUMN public.member_interactions.understood_next_steps IS 'Member confirmed the steward explained next steps.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--   SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class
--    WHERE relname = 'member_interactions';   -- rowsecurity=t, forcerowsecurity=t
--
--   -- anon cannot insert (no policy) — the API route uses service_role:
--   --   POST /api/log-interaction { steward_id, confirmed, topic, understood_next_steps }
--   -- authenticated admin → reads the tenant's interactions; steward → their own.
--
-- Known follow-ups: an admin "Representation activity" view; export for DFR
-- case files; optional member contact field if a union wants follow-up consent.
-- ════════════════════════════════════════════════════════════════════════
