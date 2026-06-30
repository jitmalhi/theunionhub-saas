-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0018 — knowledge_entries (Steward Knowledge Capture)
-- ════════════════════════════════════════════════════════════════════════
-- Institutional memory captured by stewards: the "if I were unavailable
-- tomorrow, here's what you'd need" handoff brief. Tenant-scoped, and authored
-- by a specific steward.
--
-- Access model (mirrors the stewards self-or-admin pattern, 0013):
--   · A steward reads/writes their OWN entries (user_id = auth.uid()).
--   · A tenant ADMIN reads/writes any entry in the tenant — the continuity
--     backstop, since the whole point is that someone can pick up the case.
--   · authenticated only; NO anon access.
--   NOTE: this does NOT (yet) let one steward read another steward's entries.
--   If steward-to-steward handoff is desired, broaden the SELECT policy (see
--   end of file) — that needs a "is a steward in this tenant" check.
--
-- Conventions inherited:
--   · tenant_id NOT NULL REFERENCES tenants ON DELETE RESTRICT
--   · public.get_request_tenant_id()   (0002) — tenant from x-tenant-id
--   · public.is_request_tenant_admin() (0008) — admin gate
--   · public.set_updated_at()          (0001) — updated_at trigger
--   · ENABLE + FORCE RLS; no policy for a role = no access.
--
-- Prerequisites: 0001, 0002, 0008.
-- Idempotency: IF NOT EXISTS / DROP … IF EXISTS. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ─── 1 · table ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.knowledge_entries (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  tenant_id     uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,

  -- Author. Defaults to the caller so the client doesn't have to send it;
  -- the INSERT policy still pins it to auth.uid(). CASCADE: an entry is the
  -- author's note — if the account is removed, the note goes with it.
  user_id       uuid        NOT NULL DEFAULT auth.uid()
                            REFERENCES auth.users(id) ON DELETE CASCADE,

  title         text,                                  -- "Untitled case" allowed
  issue_type    text,                                  -- Grievance | Scheduling | …
  current_state text,                                  -- "What is the issue?"
  timeline      text,                                  -- "What have you tried?"
  handoff_notes text,                                  -- "If I'm unavailable tomorrow…"

  created_at    timestamptz NOT NULL DEFAULT NOW(),
  updated_at    timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS knowledge_entries_tenant_idx      ON public.knowledge_entries (tenant_id);
CREATE INDEX IF NOT EXISTS knowledge_entries_tenant_user_idx ON public.knowledge_entries (tenant_id, user_id);
CREATE INDEX IF NOT EXISTS knowledge_entries_updated_idx     ON public.knowledge_entries (updated_at DESC);

DROP TRIGGER IF EXISTS knowledge_entries_set_updated_at ON public.knowledge_entries;
CREATE TRIGGER knowledge_entries_set_updated_at
  BEFORE UPDATE ON public.knowledge_entries
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();


-- ─── 2 · Row Level Security ─────────────────────────────────────────────
ALTER TABLE public.knowledge_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.knowledge_entries FORCE  ROW LEVEL SECURITY;

-- SELECT — own entries, or any in-tenant entry if you're an admin.
DROP POLICY IF EXISTS knowledge_entries_read ON public.knowledge_entries;
CREATE POLICY knowledge_entries_read
  ON public.knowledge_entries
  FOR SELECT
  TO authenticated
  USING (
    tenant_id = public.get_request_tenant_id()
    AND (user_id = auth.uid() OR public.is_request_tenant_admin())
  );

-- INSERT — only as yourself, only into your tenant.
DROP POLICY IF EXISTS knowledge_entries_insert ON public.knowledge_entries;
CREATE POLICY knowledge_entries_insert
  ON public.knowledge_entries
  FOR INSERT
  TO authenticated
  WITH CHECK (
    tenant_id = public.get_request_tenant_id()
    AND user_id = auth.uid()
  );

-- UPDATE — author or admin; row stays in-tenant and (for the author) stays theirs.
DROP POLICY IF EXISTS knowledge_entries_update ON public.knowledge_entries;
CREATE POLICY knowledge_entries_update
  ON public.knowledge_entries
  FOR UPDATE
  TO authenticated
  USING (
    tenant_id = public.get_request_tenant_id()
    AND (user_id = auth.uid() OR public.is_request_tenant_admin())
  )
  WITH CHECK (
    tenant_id = public.get_request_tenant_id()
    AND (user_id = auth.uid() OR public.is_request_tenant_admin())
  );

-- DELETE — author or admin.
DROP POLICY IF EXISTS knowledge_entries_delete ON public.knowledge_entries;
CREATE POLICY knowledge_entries_delete
  ON public.knowledge_entries
  FOR DELETE
  TO authenticated
  USING (
    tenant_id = public.get_request_tenant_id()
    AND (user_id = auth.uid() OR public.is_request_tenant_admin())
  );


-- ─── 3 · Comments ───────────────────────────────────────────────────────
COMMENT ON TABLE  public.knowledge_entries            IS 'Steward Knowledge Capture: tenant-scoped handoff briefs (current state / timeline / handoff). authenticated-only. Readable/writable by the author (user_id) or a tenant admin.';
COMMENT ON COLUMN public.knowledge_entries.user_id    IS 'Author. DEFAULT auth.uid(); INSERT policy pins it to the caller.';
COMMENT ON COLUMN public.knowledge_entries.handoff_notes IS '"What would the next person need to know if you were unavailable tomorrow?"';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--   SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class
--    WHERE relname = 'knowledge_entries';   -- rowsecurity=t, forcerowsecurity=t
--
--   -- anon → [] (no policy). authenticated steward → only their own rows.
--   -- authenticated admin → all rows in the tenant.
--
-- ── Optional: steward-to-steward handoff ────────────────────────────────
-- To let any steward in the tenant read entries (true cross-cover handoff),
-- replace the SELECT USING with a membership check, e.g.:
--   USING (
--     tenant_id = public.get_request_tenant_id()
--     AND (
--       user_id = auth.uid()
--       OR public.is_request_tenant_admin()
--       OR EXISTS (SELECT 1 FROM public.stewards s
--                   WHERE s.user_id = auth.uid()
--                     AND s.tenant_id = public.get_request_tenant_id())
--     )
--   )
-- Known follow-ups: a "my captures" list view; link an entry to a grievance.
-- ════════════════════════════════════════════════════════════════════════
