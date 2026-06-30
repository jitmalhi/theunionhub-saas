-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0013 — stewards + steward_analytics
-- ════════════════════════════════════════════════════════════════════════
-- Introduces shop stewards as first-class, tenant-scoped records plus a
-- lightweight scan-event log used to drive a public "scan the QR, see your
-- steward" surface and build a vCard on the fly.
--
-- A steward is a worker who represents members at a worksite / department.
--   · owned by exactly one tenant         (FK → public.tenants)
--   · MAY be linked to an auth.users acct  (FK → auth.users, NULLABLE)
--     so they can sign in and self-edit. NULLABLE is deliberate: an admin
--     pre-creates the steward and prints a permanent QR before the steward
--     has ever logged in.
--   · MAY be linked to their member record (FK → public.members)
--
-- Access model (per product decision):
--   · anon            — read-only SELECT on stewards, tenant-scoped. The
--                       public QR page reads name / title / contact directly
--                       to render the page and assemble the vCard. anon has
--                       NO write access anywhere.
--   · authenticated   — a steward self-edits their own row; tenant admins
--                       manage the whole roster (INSERT/UPDATE/DELETE).
--                       Field-level limits on self-edit are enforced in the
--                       APP LAYER (no DB guard trigger, by design).
--   · service_role    — bypasses RLS. Scan analytics are written ONLY here:
--                       the API route records each scan with the service_role
--                       client, so the public can't spam or forge the
--                       analytics tables (no anon/authenticated INSERT policy).
--
-- Conventions inherited from earlier migrations:
--   · tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT
--   · public.get_request_tenant_id()    (0002) — tenant from x-tenant-id
--   · public.is_request_tenant_admin()  (0008) — admin gate for RLS
--   · public.set_updated_at()           (0001) — updated_at trigger fn
--   · ENABLE + FORCE ROW LEVEL SECURITY; no policy for a role = no access.
--
-- Prerequisites: 0001 (tenants + set_updated_at), 0002 (members +
--                get_request_tenant_id), 0006 (is_tenant_admin),
--                0008 (is_request_tenant_admin).
--
-- Idempotency: tables use IF NOT EXISTS; policies are DROP … IF EXISTS then
-- CREATE; triggers are DROP … IF EXISTS then CREATE. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ─── 1 · stewards table ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.stewards (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Owning tenant. RESTRICT, not CASCADE: tenants are archived (status
  -- flip), never hard-deleted while child rows exist — mirrors members.
  tenant_id     uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,

  -- The auth.users account this steward signs in as. NULLABLE on purpose:
  -- admins pre-create stewards (and print permanent QRs) before the person
  -- ever logs in. ON DELETE SET NULL preserves the record (and its QR / scan
  -- history) if the auth account is later removed — it just unlinks and
  -- disables self-edit.
  user_id       uuid        REFERENCES auth.users(id) ON DELETE SET NULL,

  -- Optional link to this steward's own member record. SET NULL so a member
  -- purge doesn't cascade-delete the steward.
  member_id     uuid        REFERENCES public.members(id) ON DELETE SET NULL,

  -- Shown on the public scan page / vCard.
  full_name     text        NOT NULL,
  title         text        NOT NULL DEFAULT 'Steward',   -- position (vCard TITLE)
  email         text,                                     -- vCard EMAIL
  phone         text,                                     -- vCard TEL
  worksite      text,                                     -- area / shop / dept
  bio           text,
  photo_url     text,                                     -- tenant-assets path

  status        text        NOT NULL DEFAULT 'active',
  appointed_at  date,

  created_at    timestamptz NOT NULL DEFAULT NOW(),
  updated_at    timestamptz NOT NULL DEFAULT NOW(),
  created_by    uuid        REFERENCES auth.users(id) ON DELETE SET NULL,

  CONSTRAINT stewards_full_name_not_blank
    CHECK (length(trim(full_name)) > 0),

  -- Same lifecycle vocabulary as members.status (0002).
  CONSTRAINT stewards_status_known
    CHECK (status IN ('active', 'inactive', 'suspended', 'pending')),

  -- Loose email shape check (same pattern as tenants.contact_email).
  CONSTRAINT stewards_email_shape
    CHECK (email IS NULL OR email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),

  -- One steward record per (tenant, user). Multiple NULL-user rows allowed
  -- (Postgres treats NULLs as distinct) so a tenant can hold many
  -- not-yet-linked stewards.
  CONSTRAINT stewards_tenant_user_unique UNIQUE (tenant_id, user_id)
);

CREATE INDEX IF NOT EXISTS stewards_tenant_idx        ON public.stewards (tenant_id);
CREATE INDEX IF NOT EXISTS stewards_tenant_status_idx ON public.stewards (tenant_id, status);
CREATE INDEX IF NOT EXISTS stewards_user_idx          ON public.stewards (user_id);
CREATE INDEX IF NOT EXISTS stewards_member_idx        ON public.stewards (member_id);

DROP TRIGGER IF EXISTS stewards_set_updated_at ON public.stewards;
CREATE TRIGGER stewards_set_updated_at
  BEFORE UPDATE ON public.stewards
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();


-- ─── 2 · steward_analytics table ────────────────────────────────────────
-- Lightweight, append-only scan log: one row per QR scan. Intentionally
-- minimal (id, steward_id, scanned_at, device_type). Written ONLY by the
-- server-side API route via the service_role client (which bypasses RLS) —
-- there is no anon/authenticated INSERT path, which keeps the public from
-- spamming or forging scan data. No updated_at — rows are immutable.
CREATE TABLE IF NOT EXISTS public.steward_analytics (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- CASCADE: a scan log is meaningless once its steward is gone, and
  -- stewards CAN be hard-deleted by admins.
  steward_id    uuid        NOT NULL REFERENCES public.stewards(id) ON DELETE CASCADE,

  scanned_at    timestamptz NOT NULL DEFAULT NOW(),
  device_type   text                                  -- e.g. mobile | tablet | desktop
);

CREATE INDEX IF NOT EXISTS steward_analytics_steward_idx ON public.steward_analytics (steward_id);
CREATE INDEX IF NOT EXISTS steward_analytics_scanned_idx ON public.steward_analytics (scanned_at DESC);


-- ─── 3 · Row Level Security · stewards ──────────────────────────────────
ALTER TABLE public.stewards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stewards FORCE  ROW LEVEL SECURITY;

-- 3a · SELECT — public, but tenant-scoped. The QR page (anon) and any
--      signed-in user read stewards belonging to the request's tenant. The
--      x-tenant-id header is set by the edge middleware on every subdomain
--      request, so the public scan read is direct and fast. Tenant scoping
--      preserves the multi-tenant boundary (no cross-union leakage).
DROP POLICY IF EXISTS stewards_public_read ON public.stewards;
CREATE POLICY stewards_public_read
  ON public.stewards
  FOR SELECT
  TO anon, authenticated
  USING (tenant_id = public.get_request_tenant_id());

-- 3b · INSERT — admins only, into their own tenant.
DROP POLICY IF EXISTS stewards_admin_insert ON public.stewards;
CREATE POLICY stewards_admin_insert
  ON public.stewards
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_request_tenant_admin()
    AND tenant_id = public.get_request_tenant_id()
  );

-- 3c · UPDATE — a tenant admin may update any steward in their tenant; a
--      linked steward may self-edit their own row. WITH CHECK keeps the row
--      inside the current tenant. Which COLUMNS a steward may change is
--      enforced in the app layer (no DB guard trigger, per product decision).
DROP POLICY IF EXISTS stewards_admin_or_self_update ON public.stewards;
CREATE POLICY stewards_admin_or_self_update
  ON public.stewards
  FOR UPDATE
  TO authenticated
  USING (
    public.is_request_tenant_admin()
    OR (user_id = auth.uid() AND tenant_id = public.get_request_tenant_id())
  )
  WITH CHECK (
    tenant_id = public.get_request_tenant_id()
    AND (
      public.is_request_tenant_admin()
      OR user_id = auth.uid()
    )
  );

-- 3d · DELETE — admins only (offboarding cascades the scan log).
DROP POLICY IF EXISTS stewards_admin_delete ON public.stewards;
CREATE POLICY stewards_admin_delete
  ON public.stewards
  FOR DELETE
  TO authenticated
  USING (public.is_request_tenant_admin());


-- ─── 4 · Row Level Security · steward_analytics ─────────────────────────
ALTER TABLE public.steward_analytics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.steward_analytics FORCE  ROW LEVEL SECURITY;

-- No INSERT policy. Scans are recorded exclusively by the server-side API
-- route using the service_role client, which bypasses RLS. Keeping write
-- access off anon/authenticated entirely is what prevents public spam or
-- fraud on the analytics tables — a forged scan would need the secret
-- service-role key, which never reaches the browser.

-- 4a · SELECT — admins read all scans in their tenant; a steward reads scans
--      of their own QR. Derived through stewards (steward_analytics has no
--      tenant_id of its own — kept deliberately lightweight).
DROP POLICY IF EXISTS steward_analytics_admin_or_self_read ON public.steward_analytics;
CREATE POLICY steward_analytics_admin_or_self_read
  ON public.steward_analytics
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.stewards s
       WHERE s.id        = steward_analytics.steward_id
         AND s.tenant_id = public.get_request_tenant_id()
         AND (public.is_request_tenant_admin() OR s.user_id = auth.uid())
    )
  );

-- No UPDATE/DELETE policies: the scan log is append-only for everyone except
-- the service role (which bypasses RLS for retention / cleanup jobs).


-- ─── 5 · Comments ───────────────────────────────────────────────────────
COMMENT ON TABLE  public.stewards            IS 'Shop stewards: tenant-scoped representatives. anon-readable (tenant-scoped) for the public QR / vCard page. Optionally linked to an auth.users account (self-edit) and a member record.';
COMMENT ON COLUMN public.stewards.user_id    IS 'auth.users account the steward signs in as. NULL until they sign in (admins pre-create + print QR first); ON DELETE SET NULL preserves history. Enables self-edit.';
COMMENT ON COLUMN public.stewards.title      IS 'Position shown on the scan page and used as vCard TITLE.';
COMMENT ON COLUMN public.stewards.member_id  IS 'Optional link to the steward''s own public.members row. SET NULL on member delete.';

COMMENT ON TABLE  public.steward_analytics            IS 'Append-only QR-scan log, one row per scan. Lightweight by design (no tenant_id / updated_at). Written only by the server-side service_role client; admins read all-in-tenant, stewards read their own. Tenant scoping derived via stewards.';
COMMENT ON COLUMN public.steward_analytics.steward_id  IS 'Scanned steward. ON DELETE CASCADE.';
COMMENT ON COLUMN public.steward_analytics.device_type IS 'Free-text client hint, e.g. mobile | tablet | desktop. Set by the scan page.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Tables exist with RLS forced:
--   SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class
--    WHERE relname IN ('stewards', 'steward_analytics');
--   -- Expect rowsecurity=t, forcerowsecurity=t for both.
--
--   -- FKs are in place:
--   SELECT conname, confrelid::regclass AS references FROM pg_constraint
--    WHERE conrelid = 'public.stewards'::regclass AND contype = 'f' ORDER BY conname;
--   -- Expect FKs → tenants, auth.users (user_id + created_by), members.
--
--   -- Public scan read (anon, with x-tenant-id for the tenant):
--   curl -s "$SUPABASE_URL/rest/v1/stewards?select=id,full_name,title,email,phone&id=eq.$STEWARD_ID" \
--        -H "apikey: $SUPABASE_ANON_KEY" -H "x-tenant-id: $TENANT_UUID"
--   -- Expect: the steward row (used to build the page + vCard).
--
--   -- Cross-tenant isolation holds (wrong tenant header → empty):
--   curl -s "$SUPABASE_URL/rest/v1/stewards?select=id&id=eq.$STEWARD_ID" \
--        -H "apikey: $SUPABASE_ANON_KEY" -H "x-tenant-id: 00000000-0000-0000-0000-000000000000"
--   -- Expect: []
--
--   -- Anon CANNOT log a scan directly (no INSERT policy):
--   curl -s -X POST "$SUPABASE_URL/rest/v1/steward_analytics" \
--        -H "apikey: $SUPABASE_ANON_KEY" -H "x-tenant-id: $TENANT_UUID" \
--        -H "Content-Type: application/json" \
--        -d '{"steward_id":"'$STEWARD_ID'","device_type":"mobile"}'
--   -- Expect: 403 (RLS denies). Scans are recorded server-side only:
--
--   -- Server-side scan record (service_role key, from the API route — never
--   -- the browser). Bypasses RLS:
--   curl -s -X POST "$SUPABASE_URL/rest/v1/steward_analytics" \
--        -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
--        -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
--        -H "Content-Type: application/json" \
--        -d '{"steward_id":"'$STEWARD_ID'","device_type":"mobile"}'
--   -- Expect: 201.
--
--   -- Steward self-edits their bio (authenticated as that steward):
--   UPDATE public.stewards SET bio = 'Day shift, Plant 2.' WHERE user_id = auth.uid();
--   -- Expect: 1 row. (Field-level limits are enforced app-side.)
--
-- Known follow-ups (separate slices, none blocking):
--   · Column-narrow the anon read via a view or column GRANTs if internal
--     ids (user_id, member_id, created_by) should not be visible to anon.
--   · audit_log integration for steward create/update/delete + self-edits.
--   · Retention job on steward_analytics (service role) if scan volume grows.
-- ════════════════════════════════════════════════════════════════════════
