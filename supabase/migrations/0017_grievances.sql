-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0017 — grievances (tenant-isolated)
-- ════════════════════════════════════════════════════════════════════════
-- A core table for grievance tracking, owned by exactly one tenant (union
-- local) and isolated by Row Level Security. Unlike stewards (0013), which are
-- anon-readable for the public QR page, grievances are SENSITIVE: there is NO
-- anon access at all. Every policy is scoped to authenticated callers whose
-- request tenant (x-tenant-id header → public.get_request_tenant_id()) matches
-- the row's tenant_id.
--
-- Conventions inherited from earlier migrations:
--   · tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT
--   · public.get_request_tenant_id()   (0002) — tenant from x-tenant-id header
--   · public.is_request_tenant_admin() (0008) — admin membership gate
--   · public.set_updated_at()          (0001) — updated_at trigger fn
--   · ENABLE + FORCE ROW LEVEL SECURITY; no policy for a role = no access.
--
-- SECURITY MODEL — admin-gated (HARDENED), per product decision:
--   Access is restricted to VERIFIED TENANT ADMINS only. Every policy requires
--   BOTH:
--     · tenant_id = get_request_tenant_id()   — row belongs to the request
--       tenant (x-tenant-id header), AND
--     · is_request_tenant_admin()             — the caller (auth.uid()) is a
--       real admin of that tenant via the tenant_admins table.
--   The second clause is the key: it binds access to membership, not just a
--   header, so a signed-in user of tenant A who forges tenant B's x-tenant-id
--   is rejected (they are not a B admin). anon has no policy at all → no access.
--   (A relaxed "any authenticated user in the tenant" variant — header match
--   only — is documented at the end of this file if the model ever broadens.)
--
-- Prerequisites: 0001 (tenants + set_updated_at), 0002 (get_request_tenant_id),
--                0008 (is_request_tenant_admin — REQUIRED by these policies).
--
-- Idempotency: table uses IF NOT EXISTS; policies are DROP … IF EXISTS then
-- CREATE; trigger is DROP … IF EXISTS then CREATE. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ─── 1 · grievances table ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.grievances (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Owning tenant. RESTRICT, not CASCADE: tenants are archived, never
  -- hard-deleted while child rows exist — mirrors members / stewards.
  tenant_id       uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,

  member_name     text        NOT NULL,
  grievance_type  text,                                   -- free-text category
  status          text        NOT NULL DEFAULT 'Open',
  description     text,

  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),

  CONSTRAINT grievances_member_name_not_blank
    CHECK (length(trim(member_name)) > 0),

  -- Lifecycle vocabulary as specified. Extend this list (or drop the
  -- constraint) if the workflow grows more states.
  CONSTRAINT grievances_status_known
    CHECK (status IN ('Open', 'In Progress', 'Resolved'))
);

CREATE INDEX IF NOT EXISTS grievances_tenant_idx        ON public.grievances (tenant_id);
CREATE INDEX IF NOT EXISTS grievances_tenant_status_idx ON public.grievances (tenant_id, status);
CREATE INDEX IF NOT EXISTS grievances_created_idx       ON public.grievances (created_at DESC);

DROP TRIGGER IF EXISTS grievances_set_updated_at ON public.grievances;
CREATE TRIGGER grievances_set_updated_at
  BEFORE UPDATE ON public.grievances
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();


-- ─── 2 · Row Level Security ─────────────────────────────────────────────
ALTER TABLE public.grievances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grievances FORCE  ROW LEVEL SECURITY;

-- HARDENED (admin-gated): authenticated ONLY (no anon policy → anon has zero
-- access), AND the caller must be a verified admin of the request tenant.
-- is_request_tenant_admin() binds auth.uid() to the tenant via tenant_admins,
-- so a forged x-tenant-id from another tenant's user is rejected — real
-- membership, not just a header. The explicit tenant_id = get_request_tenant_id()
-- additionally scopes rows to the request tenant. INSERT/UPDATE use WITH CHECK
-- so a row can't be created in, or moved to, another tenant.

DROP POLICY IF EXISTS grievances_tenant_select ON public.grievances;
CREATE POLICY grievances_tenant_select
  ON public.grievances
  FOR SELECT
  TO authenticated
  USING (
    tenant_id = public.get_request_tenant_id()
    AND public.is_request_tenant_admin()
  );

DROP POLICY IF EXISTS grievances_tenant_insert ON public.grievances;
CREATE POLICY grievances_tenant_insert
  ON public.grievances
  FOR INSERT
  TO authenticated
  WITH CHECK (
    tenant_id = public.get_request_tenant_id()
    AND public.is_request_tenant_admin()
  );

DROP POLICY IF EXISTS grievances_tenant_update ON public.grievances;
CREATE POLICY grievances_tenant_update
  ON public.grievances
  FOR UPDATE
  TO authenticated
  USING (
    tenant_id = public.get_request_tenant_id()
    AND public.is_request_tenant_admin()
  )
  WITH CHECK (
    tenant_id = public.get_request_tenant_id()
    AND public.is_request_tenant_admin()
  );

DROP POLICY IF EXISTS grievances_tenant_delete ON public.grievances;
CREATE POLICY grievances_tenant_delete
  ON public.grievances
  FOR DELETE
  TO authenticated
  USING (
    tenant_id = public.get_request_tenant_id()
    AND public.is_request_tenant_admin()
  );


-- ─── 3 · Comments ───────────────────────────────────────────────────────
COMMENT ON TABLE  public.grievances           IS 'Tenant-scoped grievance records. SENSITIVE: admin-gated — readable/writable only by verified admins of the request tenant (tenant_id = get_request_tenant_id() AND is_request_tenant_admin()). No anon access.';
COMMENT ON COLUMN public.grievances.tenant_id IS 'Owning tenant. NOT NULL. FK → tenants ON DELETE RESTRICT.';
COMMENT ON COLUMN public.grievances.status    IS 'Lifecycle: Open | In Progress | Resolved (CHECK grievances_status_known).';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- RLS forced:
--   SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class
--    WHERE relname = 'grievances';   -- expect rowsecurity=t, forcerowsecurity=t
--
--   -- anon is fully blocked (no policy → []):
--   curl -s "$SUPABASE_URL/rest/v1/grievances?select=id" \
--        -H "apikey: $SUPABASE_ANON_KEY" -H "x-tenant-id: $TENANT_UUID"
--   -- expect: [] (anon role, no SELECT policy)
--
--   -- authenticated ADMIN of the tenant, correct header → that tenant's rows.
--   -- authenticated NON-admin (e.g. a steward), correct header → [] (admin gate).
--   -- authenticated admin of tenant A, forging tenant B's header → [] (the
--   --   is_request_tenant_admin() check fails for B — this is the whole point).
--
-- ── RELAXED (any authenticated tenant user) variant ─────────────────────
-- If access should ever broaden beyond admins to any authenticated user in the
-- tenant, drop the `AND public.is_request_tenant_admin()` clause from each
-- policy, leaving header-match only:
--
--   USING (tenant_id = public.get_request_tenant_id())
--   -- and the matching WITH CHECK on INSERT/UPDATE.
--
-- NOTE: that relaxed form trusts the x-tenant-id header alone, so it does NOT
-- stop a signed-in user from forging another tenant's id. Only use it if every
-- authenticated user is already trusted across the tenant boundary.
--
-- Known follow-ups (separate slices):
--   · created_by uuid REFERENCES auth.users — attribute who filed each grievance.
--   · assigned_to (steward/officer) once grievance routing is designed.
--   · audit_log integration for create/update/delete.
-- ════════════════════════════════════════════════════════════════════════
