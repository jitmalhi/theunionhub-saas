-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0001 — public.tenants
-- ════════════════════════════════════════════════════════════════════════
-- Creates the root table for multi-tenancy. Every union (local183,
-- local419, …) is one row here. Every other tenant-scoped table in the
-- system (members, verifications, audit_log) gains a tenant_id uuid
-- column with FK → public.tenants(id) in a later migration.
--
-- Read by:
--   · api/_middleware.js  →  SELECT id, slug, display_name, accent_hex,
--                            status FROM tenants WHERE slug = $1 LIMIT 1
--   · scripts/new-tenant.mjs  (insert + status flip)
--   · admin tools (future)
--
-- The reserved-slug list, the slug regex, and the status enum are
-- duplicated in three places by design:
--   1. api/_middleware.js          (RESERVED_SLUGS Set, status checks)
--   2. tenants/README.md           (provisioning docs, reserved list)
--   3. THIS FILE                   (CHECK constraints, enum)
-- Update all three in the same commit or routing diverges from the DB.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─── 1 · Extensions ──────────────────────────────────────────────────────
-- pgcrypto provides gen_random_uuid(). Supabase enables it by default,
-- but we declare it explicitly so this migration is portable.
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- ─── 2 · Enum: tenant_status ─────────────────────────────────────────────
-- The middleware branches on this exact set. Adding a value here without
-- updating api/_middleware.js will silently route the new state as 404.
--
--   pending   · provisioned, awaiting DNS check + first admin sign-in
--   active    · fully live; renders /tenants/_template
--   suspended · payment / policy hold; renders 404, x-tenant-status leaks state
--   archived  · intentionally removed; renders 410 Gone
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'tenant_status') THEN
    CREATE TYPE public.tenant_status AS ENUM (
      'pending',
      'active',
      'suspended',
      'archived'
    );
  END IF;
END $$;


-- ─── 3 · Utility functions ───────────────────────────────────────────────

-- 3.1  Bump updated_at on every UPDATE.
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

-- 3.2  Stamp archived_at when status flips to 'archived'; clear it if a
--      tenant is un-archived (rare, but the trigger should be reversible).
CREATE OR REPLACE FUNCTION public.set_archived_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'archived'
     AND (OLD.status IS NULL OR OLD.status <> 'archived') THEN
    NEW.archived_at := NOW();
  ELSIF NEW.status <> 'archived' THEN
    NEW.archived_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;


-- ─── 4 · Main table ──────────────────────────────────────────────────────
CREATE TABLE public.tenants (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- The subdomain label. URL-safe, case-insensitive, 2-32 chars,
  -- starts/ends with alphanumeric. Hyphens allowed in the middle.
  slug            text NOT NULL,

  -- Human-readable name shown on the card and verify pages.
  display_name    text NOT NULL,

  -- The union local number, e.g. '183' for IBEW Local 183. Stored as
  -- text because some unions use alphanumeric identifiers (e.g. 'B-9').
  local_number    text,

  -- The parent organisation, e.g. 'IBEW', 'UA', 'LIUNA'. Free-text for
  -- now; promote to a lookup table if the cardinality matters later.
  union_type      text,

  -- One accent colour. Validated app-side for WCAG AA contrast vs
  -- --off-white (#F5F4F1); rejected by scripts/new-tenant.mjs if it
  -- fails. SQL only checks format here.
  accent_hex      text NOT NULL DEFAULT '#0F6E56',

  -- Where the tenant's logo lives in Supabase Storage. Resolved by the
  -- card/verify pages; nullable so a tenant can launch without a logo.
  logo_url        text,

  -- Primary admin email; magic-link is issued here on provisioning.
  contact_email   text NOT NULL,

  status          public.tenant_status NOT NULL DEFAULT 'pending',

  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  archived_at     timestamptz,

  -- ─── Constraints ──────────────────────────────────────────────────────

  -- 4.1  Slug uniqueness — the routing primitive. Case-insensitive in
  --      practice because the middleware lower-cases hosts before lookup,
  --      and a CHECK below forbids uppercase letters.
  CONSTRAINT tenants_slug_unique UNIQUE (slug),

  -- 4.2  Slug format: 2-32 chars, lowercase alnum + hyphens, no leading
  --      or trailing hyphen. Mirrors the regex in tenants/README.md.
  CONSTRAINT tenants_slug_format
    CHECK (slug ~ '^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$'),

  -- 4.3  Reserved slugs — must match RESERVED_SLUGS in api/_middleware.js.
  CONSTRAINT tenants_slug_not_reserved
    CHECK (slug NOT IN (
      'www', 'app', 'api', 'admin', 'status', 'docs', 'blog',
      'mail', 'assets', 'cdn', 'static', 'demo-www'
    )),

  -- 4.4  Accent must be a 6-digit hex with leading #.
  CONSTRAINT tenants_accent_hex_format
    CHECK (accent_hex ~ '^#[0-9A-Fa-f]{6}$'),

  -- 4.5  Display name is not blank or whitespace.
  CONSTRAINT tenants_display_name_not_blank
    CHECK (length(trim(display_name)) > 0),

  -- 4.6  Loose email check. RFC 5322 is famously un-regexable; this
  --      catches obvious typos. Real deliverability is the auth flow's job.
  CONSTRAINT tenants_contact_email_shape
    CHECK (contact_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),

  -- 4.7  Internal consistency: archived rows must have archived_at set;
  --      non-archived rows must not.
  CONSTRAINT tenants_archived_at_consistency
    CHECK (
      (status = 'archived' AND archived_at IS NOT NULL)
      OR
      (status <> 'archived' AND archived_at IS NULL)
    )
);


-- ─── 5 · Indexes ─────────────────────────────────────────────────────────
-- slug uniqueness already creates an index. Add status for the admin
-- "list active tenants" query and created_at for chronological listing.
CREATE INDEX tenants_status_idx     ON public.tenants (status);
CREATE INDEX tenants_created_at_idx ON public.tenants (created_at DESC);


-- ─── 6 · Triggers ────────────────────────────────────────────────────────
CREATE TRIGGER tenants_set_updated_at
  BEFORE UPDATE ON public.tenants
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER tenants_set_archived_at
  BEFORE INSERT OR UPDATE OF status ON public.tenants
  FOR EACH ROW
  EXECUTE FUNCTION public.set_archived_at();


-- ─── 7 · Row Level Security ──────────────────────────────────────────────
-- Anon clients (including the edge middleware) need to resolve any slug
-- → tenant row to answer routing questions correctly:
--
--   active     → render the template + inject headers
--   archived   → 410 Gone
--   suspended  → 404 + x-tenant-status header
--   not found  → 404
--
-- That means anon SELECT must be allowed across *all* statuses. The
-- columns visible here are all already public (the subdomain itself,
-- the displayed name, the brand accent) — there is no secret to keep.
-- Sensitive fields (billing, internal notes) belong in a separate
-- private table introduced in a later migration, not here.
--
-- Writes are restricted to the service role, which bypasses RLS. The
-- provisioning script (scripts/new-tenant.mjs) and the admin app use
-- SUPABASE_SERVICE_ROLE_KEY; no anonymous or authenticated client can
-- mutate this table directly.

ALTER TABLE public.tenants ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenants_anon_read
  ON public.tenants
  FOR SELECT
  TO anon, authenticated
  USING (true);

-- No INSERT/UPDATE/DELETE policies → only service_role can mutate.


-- ─── 8 · Comments (for Supabase Studio + psql \d+) ──────────────────────
COMMENT ON TABLE  public.tenants                 IS 'One row per union. The routing primitive for multi-tenancy.';
COMMENT ON COLUMN public.tenants.slug            IS 'Subdomain label; also primary lookup key from api/_middleware.js.';
COMMENT ON COLUMN public.tenants.display_name    IS 'Human-readable name rendered on card / verify pages.';
COMMENT ON COLUMN public.tenants.local_number    IS 'Union local number (text; some are alphanumeric).';
COMMENT ON COLUMN public.tenants.union_type      IS 'Parent organisation, e.g. IBEW, UA, LIUNA. Free text.';
COMMENT ON COLUMN public.tenants.accent_hex      IS 'Per-tenant accent. Must pass WCAG AA vs #F5F4F1 (enforced app-side).';
COMMENT ON COLUMN public.tenants.logo_url        IS 'Path or URL into the tenant-assets Supabase Storage bucket.';
COMMENT ON COLUMN public.tenants.contact_email   IS 'Primary admin; magic-link issued here on provisioning.';
COMMENT ON COLUMN public.tenants.status          IS 'Lifecycle state. Middleware branches on this exact set.';
COMMENT ON COLUMN public.tenants.archived_at     IS 'Stamped automatically when status flips to archived; null otherwise.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration checklist (do these out-of-band; not part of the
-- transaction above):
--
--   1. supabase/seed.sql           Insert at least one demo tenant
--                                   (slug='demo') so dev / lvh.me works.
--                                   Migration 0002 will seed the existing
--                                   prototype member IDs against it.
--
--   2. scripts/new-tenant.mjs      Implement the provisioning recipe
--                                   documented in tenants/README.md.
--                                   It writes to public.tenants using
--                                   SUPABASE_SERVICE_ROLE_KEY.
--
--   3. Verify edge cache TTL       api/_middleware.js caches tenant rows
--                                   for 60s in worker memory. Coordinate
--                                   any urgent flips by waiting that
--                                   window or invalidating manually.
-- ════════════════════════════════════════════════════════════════════════
