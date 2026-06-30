-- ═════════════════════════════════════════════════════════════════════════
-- The Union Hub · consolidated migrations 0001 → 0012  (v2 — single-tx safe)
-- ═════════════════════════════════════════════════════════════════════════
-- This version REMOVES the per-migration BEGIN; / COMMIT; pairs. Run as one
-- script in the Supabase Dashboard SQL Editor — the editor wraps it in its
-- own transaction; explicit nested BEGIN/COMMIT was prematurely closing that
-- wrapper and surfacing a confusing "column does not exist" at the tail.
-- ═════════════════════════════════════════════════════════════════════════

-- ═════════════════════════════════════════════════════════════════════════
-- The Union Hub · consolidated migrations 0001 → 0012
-- Generated: paste into Supabase Dashboard → SQL Editor → New Query → Run.
-- 
-- Apply ONCE on a fresh project. Most statements are idempotent
-- (CREATE OR REPLACE / IF NOT EXISTS) so a second run is mostly safe,
-- but DROP-then-CREATE blocks in 0008 are not — don't re-run.
-- ═════════════════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════════════════════
-- ── 0001_init_tenants
-- ═════════════════════════════════════════════════════════════════════════

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


-- ═════════════════════════════════════════════════════════════════════════
-- ── 0002_members_add_tenant_id
-- ═════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0002 — members.tenant_id + tenant-scoped RLS
-- ════════════════════════════════════════════════════════════════════════
-- Evolves the existing public.members table (or creates it from scratch
-- on a fresh database) to carry a tenant_id foreign key and locks down
-- read/write access by tenant via Row Level Security.
--
-- After this migration, every member row belongs to exactly one tenant,
-- and no anon or authenticated client can read or write a member row
-- whose tenant_id does not match the x-tenant-id header on the request.
-- The header is set by:
--   · lib/supabase.js → withTenant({ tenantId })
--   · The inline sbHeaders() helper in card.html and verify.html
--   · The edge middleware's response headers (echoed by the client)
--
-- The security boundary is the database, not the application. Application-
-- side filtering is for UX (show the right rows in lists); RLS is what
-- stops a member from local183 reading rows belonging to local419 even
-- if they guess UUIDs.
--
-- Prerequisites:
--   · Migration 0001 applied (public.tenants exists; pgcrypto enabled).
--
-- Idempotency: every block uses IF EXISTS / IF NOT EXISTS / DO …
-- EXCEPTION patterns. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════

-- ─── 1 · Ensure the members table exists ────────────────────────────────
-- On a fresh database this creates the full target schema. On prod (where
-- members already exists from the prototype) this is a no-op, and the
-- ALTER TABLE blocks below handle the evolution.
CREATE TABLE IF NOT EXISTS public.members (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name     text        NOT NULL,
  -- union_name and local_number are DENORMALISED copies of the parent
  -- tenant's display_name / local_number. They exist for prototype
  -- compatibility (card.html / verify.html read them directly). New code
  -- should JOIN to tenants instead; eventually these columns will move
  -- to a separate migration that drops them.
  union_name    text,
  local_number  text,
  member_since  date,
  status        text        NOT NULL DEFAULT 'active',
  created_at    timestamptz NOT NULL DEFAULT NOW(),
  updated_at    timestamptz NOT NULL DEFAULT NOW(),
  -- tenant_id is added below via ALTER so the same statement works whether
  -- the table was just created or pre-existed without it.
  CONSTRAINT members_status_known
    CHECK (status IN ('active', 'inactive', 'suspended', 'pending'))
);


-- ─── 2 · Add tenant_id column (nullable for backfill) ───────────────────
ALTER TABLE public.members
  ADD COLUMN IF NOT EXISTS tenant_id uuid;


-- ─── 3 · Backfill orphan rows to the demo tenant (if seeded) ────────────
-- Idempotent. Touches only rows where tenant_id IS NULL. If the demo
-- tenant doesn't exist yet (seed.sql hasn't run), this no-ops with a
-- NOTICE — re-run after seeding or assign tenant_id manually for each
-- existing row before flipping SET NOT NULL below.
DO $$
DECLARE
  v_demo_id  uuid;
  v_affected integer;
BEGIN
  SELECT id INTO v_demo_id FROM public.tenants WHERE slug = 'demo';

  IF v_demo_id IS NULL THEN
    RAISE NOTICE '[0002] no demo tenant — leaving existing members.tenant_id NULL. '
                 'Run seed.sql first, then re-run this migration (idempotent).';
    RETURN;
  END IF;

  UPDATE public.members
     SET tenant_id = v_demo_id
   WHERE tenant_id IS NULL;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RAISE NOTICE '[0002] backfilled % orphan members to demo tenant (%)', v_affected, v_demo_id;
END $$;


-- ─── 4 · Foreign key to tenants ─────────────────────────────────────────
-- ON DELETE RESTRICT is deliberate: tenants should be archived (status flip),
-- never hard-deleted while members exist. If a hard delete is truly needed,
-- the operator must reassign or remove members first — the failure is the
-- safety net.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_schema    = 'public'
      AND table_name      = 'members'
      AND constraint_name = 'members_tenant_id_fkey'
  ) THEN
    ALTER TABLE public.members
      ADD CONSTRAINT members_tenant_id_fkey
      FOREIGN KEY (tenant_id) REFERENCES public.tenants(id)
      ON DELETE RESTRICT ON UPDATE NO ACTION;
  END IF;
END $$;


-- ─── 5 · Flip tenant_id to NOT NULL when safe ───────────────────────────
-- Only sets NOT NULL when every row already has a tenant_id. Otherwise
-- leaves the column nullable and emits a NOTICE — the operator runs
--   ALTER TABLE public.members ALTER COLUMN tenant_id SET NOT NULL;
-- manually after a controlled backfill.
DO $$
DECLARE
  v_nulls integer;
BEGIN
  SELECT COUNT(*) INTO v_nulls FROM public.members WHERE tenant_id IS NULL;

  IF v_nulls = 0 THEN
    BEGIN
      ALTER TABLE public.members ALTER COLUMN tenant_id SET NOT NULL;
      RAISE NOTICE '[0002] members.tenant_id is now NOT NULL';
    EXCEPTION WHEN OTHERS THEN
      -- Already NOT NULL, or some other already-handled state. Ignore.
      NULL;
    END;
  ELSE
    RAISE NOTICE '[0002] % members still have NULL tenant_id; leaving column nullable. '
                 'Backfill manually, then: '
                 'ALTER TABLE public.members ALTER COLUMN tenant_id SET NOT NULL;', v_nulls;
  END IF;
END $$;


-- ─── 6 · Index for tenant-scoped queries ────────────────────────────────
CREATE INDEX IF NOT EXISTS members_tenant_id_idx ON public.members (tenant_id);
-- Composite index for the common case: "all members of this tenant by status."
CREATE INDEX IF NOT EXISTS members_tenant_status_idx
  ON public.members (tenant_id, status);


-- ─── 7 · updated_at trigger ─────────────────────────────────────────────
-- Reuses the public.set_updated_at() function defined in migration 0001.
DROP TRIGGER IF EXISTS members_set_updated_at ON public.members;
CREATE TRIGGER members_set_updated_at
  BEFORE UPDATE ON public.members
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();


-- ─── 8 · Tenant resolution function (shared across all RLS policies) ────
-- Called by every tenant-scoped RLS policy. Reads x-tenant-id from the
-- PostgREST `request.headers` GUC, validates it as a uuid, and returns
-- NULL on any error (which causes the policy comparison
--   tenant_id = NULL
-- to be NULL — treated as false by USING clauses — so a malformed or
-- missing header denies access by default).
--
-- STABLE so PostgreSQL can cache the value across rows within one query
-- (request headers don't change mid-statement). SECURITY INVOKER so it
-- runs with the caller's privileges — there's no privilege escalation
-- vector even if a future migration uses this in a SECURITY DEFINER
-- function.
--
-- Reused unchanged by future migrations that add tenant-scoped tables
-- (verifications, audit_log, member_documents, …).
CREATE OR REPLACE FUNCTION public.get_request_tenant_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_raw text;
BEGIN
  BEGIN
    v_raw := current_setting('request.headers', true)::json ->> 'x-tenant-id';
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;

  IF v_raw IS NULL OR v_raw = '' THEN
    RETURN NULL;
  END IF;

  BEGIN
    RETURN v_raw::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN NULL;
  END;
END;
$$;

COMMENT ON FUNCTION public.get_request_tenant_id() IS
  'Reads x-tenant-id from the PostgREST request.headers GUC and returns it as uuid. '
  'Returns NULL when the header is missing, empty, or malformed. Used by RLS '
  'policies on all tenant-scoped tables to enforce isolation. STABLE + INVOKER.';


-- ─── 9 · Enable Row Level Security ──────────────────────────────────────
-- This is the actual security boundary. The middleware setting x-tenant-id,
-- the client sending it — those are UX/plumbing. RLS below is what stops
-- cross-tenant reads at the database level even if the client lies or the
-- middleware is bypassed entirely.
ALTER TABLE public.members ENABLE ROW LEVEL SECURITY;

-- Force RLS for the table owner too. Without this, the table owner (the
-- role that ran the migration) bypasses RLS, which is a footgun if any
-- admin tool runs queries as the owner instead of via the service role.
ALTER TABLE public.members FORCE ROW LEVEL SECURITY;


-- ─── 10 · Policies ──────────────────────────────────────────────────────
-- service_role bypasses RLS unconditionally — no policy needed for it.
-- All policies below scope to anon + authenticated, the two roles that
-- run with RLS enforced.

-- 10a · SELECT: anon (verifier scanning a QR) and authenticated (member,
--       admin) can read rows for their own tenant only.
DROP POLICY IF EXISTS members_tenant_isolated_read ON public.members;
CREATE POLICY members_tenant_isolated_read
  ON public.members
  FOR SELECT
  TO anon, authenticated
  USING (tenant_id = public.get_request_tenant_id());

-- 10b · INSERT: only authenticated users, and only into their own tenant.
DROP POLICY IF EXISTS members_tenant_isolated_insert ON public.members;
CREATE POLICY members_tenant_isolated_insert
  ON public.members
  FOR INSERT
  TO authenticated
  WITH CHECK (tenant_id = public.get_request_tenant_id());

-- 10c · UPDATE: authenticated users can update rows in their own tenant.
--       The WITH CHECK also blocks moving a row to a different tenant
--       (e.g. `UPDATE … SET tenant_id = other_uuid` is rejected).
DROP POLICY IF EXISTS members_tenant_isolated_update ON public.members;
CREATE POLICY members_tenant_isolated_update
  ON public.members
  FOR UPDATE
  TO authenticated
  USING      (tenant_id = public.get_request_tenant_id())
  WITH CHECK (tenant_id = public.get_request_tenant_id());

-- 10d · DELETE: authenticated users can delete rows in their own tenant.
DROP POLICY IF EXISTS members_tenant_isolated_delete ON public.members;
CREATE POLICY members_tenant_isolated_delete
  ON public.members
  FOR DELETE
  TO authenticated
  USING (tenant_id = public.get_request_tenant_id());


-- ─── 11 · Comments ──────────────────────────────────────────────────────
COMMENT ON TABLE  public.members                IS 'Member records. Tenant-scoped via tenant_id; RLS isolates by get_request_tenant_id().';
COMMENT ON COLUMN public.members.tenant_id      IS 'Owning tenant. NOT NULL once backfill completes. FK ON DELETE RESTRICT.';
COMMENT ON COLUMN public.members.union_name     IS 'DENORMALISED from tenants.display_name. Kept for prototype compat; new code should JOIN to tenants.';
COMMENT ON COLUMN public.members.local_number   IS 'DENORMALISED from tenants.local_number. Kept for prototype compat; new code should JOIN to tenants.';
COMMENT ON COLUMN public.members.status         IS 'Member lifecycle. Constrained to active|inactive|suspended|pending — verify.html branches on this.';

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Every member has a tenant?
--   SELECT COUNT(*) FROM public.members WHERE tenant_id IS NULL;
--
--   -- Demo members landed correctly (after seed.sql)?
--   SELECT id, full_name, status, tenant_id
--     FROM public.members
--    WHERE tenant_id = (SELECT id FROM public.tenants WHERE slug='demo')
--    ORDER BY status;
--
--   -- RLS active?
--   SELECT relname, relrowsecurity, relforcerowsecurity
--     FROM pg_class WHERE relname = 'members';
--   -- Expect: rowsecurity=t, forcerowsecurity=t
--
--   -- Smoke-test isolation as anon (via PostgREST):
--   curl -s "$SUPABASE_URL/rest/v1/members?select=id,status&limit=5" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: <demo-uuid>"
--   # → returns demo's members
--
--   curl -s "$SUPABASE_URL/rest/v1/members?select=id,status&limit=5" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: 00000000-0000-0000-0000-000000000000"
--   # → returns []
--
--   curl -s "$SUPABASE_URL/rest/v1/members?select=id,status&limit=5" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--   # → returns []   (no header → NULL → no match)
--
-- Known follow-ups (separate migrations):
--   · public stats RPC for marketing-site counters that need to count
--     across tenants (currently js/live.js will see 0 once this lands).
--   · DROP COLUMN members.union_name, members.local_number after all
--     readers join to tenants instead of reading denormalised copies.
--   · members.status → enum once we're sure the four values are stable.
-- ════════════════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════════════════════
-- ── 0003_public_stats
-- ═════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0003 — public.public_stats() SECURITY DEFINER
-- ════════════════════════════════════════════════════════════════════════
-- Resolves the regression introduced by migration 0002:
--
--   The marketing site's "live stats strip" (js/live.js → fetchStats) counts
--   members and active tenants across the whole platform. After 0002 turned
--   on tenant-isolated RLS on public.members, anon requests with no
--   x-tenant-id header (which is the apex marketing page's situation by
--   design — the apex has no tenant) get 0 rows back. The counter pegs at
--   zero.
--
-- This function bypasses RLS to compute global aggregate counts, returns
-- only counts (never identifiers, names, or per-row data), and is locked
-- down so only anon / authenticated can call it.
--
-- Security model — SECURITY DEFINER tripwires we explicitly defuse:
--
--   1. The function runs as its OWNER (whoever ran the migration), so it
--      sees every row in every table it reads. Body returns aggregate
--      counts only — no row data, no tenant identifiers, no member PII.
--      Add aggregate fields here; never add anything that could leak per-
--      row or per-tenant breakdowns.
--
--   2. SET search_path = public, pg_temp pins lookups to the trusted
--      schema. Without this, a user who can create objects in any schema
--      on the search_path could shadow public.members with a malicious
--      view and intercept the function's queries.
--
--   3. REVOKE EXECUTE FROM PUBLIC strips the default grant that
--      CREATE FUNCTION gives. GRANT EXECUTE then opens it back up to
--      exactly the two roles that need it. service_role bypasses all of
--      this anyway.
--
--   4. STABLE + PARALLEL SAFE let the planner cache the result across
--      rows in a single statement and farm it out to parallel workers.
--      Both are safe for read-only COUNT functions.
--
-- Prerequisites: migration 0001 (tenants). 0002 (members + tenant_id) is
-- optional — the function falls back to 0 if members doesn't exist yet.
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.public_stats()
RETURNS TABLE (
  members_count        bigint,
  locals_count         bigint,
  verifications_today  bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
STABLE
PARALLEL SAFE
AS $$
DECLARE
  v_members             bigint;
  v_locals              bigint;
  v_verifications_today bigint;
BEGIN
  -- Members: count rows that belong to ACTIVE tenants only. Members of
  -- archived / suspended tenants shouldn't inflate the marketing number
  -- the way a raw COUNT(*) FROM members would. Defensive against the
  -- members table not existing yet (database where 0002 hasn't run).
  BEGIN
    SELECT COUNT(*) INTO v_members
      FROM public.members m
      JOIN public.tenants t ON t.id = m.tenant_id
     WHERE t.status = 'active';
  EXCEPTION WHEN undefined_table THEN
    v_members := 0;
  END;

  -- Locals: active tenants only. tenants always exists (0001 prerequisite),
  -- so no EXCEPTION block needed here.
  SELECT COUNT(*) INTO v_locals
    FROM public.tenants
   WHERE status = 'active';

  -- Verifications today: defensive against verifications table not yet
  -- existing (it lands in a future migration). Returns 0 until that
  -- ships, then starts returning real counts WITHOUT needing to edit
  -- or redeploy this function — the EXCEPTION block stops catching
  -- once the table exists.
  BEGIN
    SELECT COUNT(*) INTO v_verifications_today
      FROM public.verifications
     WHERE created_at >= current_date;
  EXCEPTION WHEN undefined_table THEN
    v_verifications_today := 0;
  END;

  RETURN QUERY SELECT v_members, v_locals, v_verifications_today;
END;
$$;

-- ─── Lockdown ────────────────────────────────────────────────────────────
-- CREATE FUNCTION grants EXECUTE to PUBLIC by default. Strip that grant,
-- then re-grant explicitly to the two roles allowed to call this.
REVOKE EXECUTE ON FUNCTION public.public_stats() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.public_stats() TO anon, authenticated;

COMMENT ON FUNCTION public.public_stats() IS
  'Returns GLOBAL aggregate counts safe to expose anonymously: members of '
  'active tenants, count of active tenants, verifications today. SECURITY '
  'DEFINER bypasses RLS so the marketing site (no tenant context) sees '
  'real numbers. Returns ONLY counts — never identifiers, names, or row '
  'data. Add aggregate fields here; never add any field that exposes per-'
  'row or per-tenant breakdowns.';

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- The function exists with the expected signature?
--   \df+ public.public_stats
--
--   -- Anon can call it; service role can too:
--   curl -s "$SUPABASE_URL/rest/v1/rpc/public_stats" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--   # → [{"members_count":3,"locals_count":1,"verifications_today":0}]
--
--   -- Anon WITHOUT any tenant header gets the same numbers (the whole
--   -- point — no x-tenant-id required, this is the apex code path):
--   curl -s "$SUPABASE_URL/rest/v1/rpc/public_stats" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--
--   -- And cross-check that anon STILL can't read individual member rows
--   -- (so the function is the only authorised window into members from
--   -- the apex):
--   curl -s "$SUPABASE_URL/rest/v1/members?select=id&limit=1" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--   # → []
--
-- Known follow-ups:
--   · Materialised view + cron refresh once member counts climb into the
--     hundreds of thousands and COUNT(*) becomes hot-path expensive.
--   · Per-tenant counterpart tenant_stats(p_tenant_id uuid) called by
--     the future admin app. That one is SECURITY INVOKER + checks
--     x-tenant-id matches the arg.
-- ════════════════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════════════════════
-- ── 0004_audit_log
-- ═════════════════════════════════════════════════════════════════════════

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

   collection_date is a GENERATED column from collected_at::date, so the
   constraint and the indexes derive from the actual collection time
   automatically. UTC is assumed; locals operating across timezone
   boundaries would want to override the date derivation (out of scope).
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


-- ═════════════════════════════════════════════════════════════════════════
-- ── 0005_tenant_admin_settings
-- ═════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0005 — update_tenant_settings() RPC
-- ════════════════════════════════════════════════════════════════════════
-- Unblocks the admin settings page. RLS on public.tenants is read-only
-- by design (anyone visiting demo.theunionhub.com can SELECT to render
-- the card; nobody can mutate). The provisioning script writes via
-- service_role. The admin UI needs a third path: an authenticated user
-- who is the tenant's contact_email should be able to update the
-- non-sensitive display fields without holding the service key.
--
-- The RPC checks the calling user's email against tenants.contact_email
-- BEFORE the UPDATE. SECURITY DEFINER, so the function bypasses the
-- read-only RLS posture, but only after authorisation is proven inside
-- the function body. Then it stamps an audit_log row noting what
-- changed and who changed it.
--
-- What this RPC CANNOT change (deliberately):
--   · slug          — the routing primitive; changing it would break
--                     every existing magic-link and bookmark
--   · contact_email — changing it would let the current admin lock
--                     themselves out and hand control to another email
--   · status        — lifecycle changes (active → archived) belong in
--                     a separate admin tool with a confirmation step
--   · accent contrast — the format is checked by the table CHECK
--                       constraint; WCAG AA is enforced client-side
--                       in settings.html
--
-- Prerequisites:
--   · 0001 (tenants), 0002 (get_request_tenant_id), 0004 (audit_log).
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.update_tenant_settings(
  p_display_name text DEFAULT NULL,
  p_accent_hex   text DEFAULT NULL,
  p_local_number text DEFAULT NULL,
  p_union_type   text DEFAULT NULL
)
RETURNS public.tenants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id    uuid;
  v_user_id      uuid;
  v_user_email   text;
  v_tenant_email text;
  v_result       public.tenants%ROWTYPE;
  v_changed      jsonb;
BEGIN
  -- 1 · Tenant context. Without x-tenant-id we have no idea which
  --     tenant to update; reject loudly so the UI can surface it.
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context'
      USING HINT = 'x-tenant-id header is missing or malformed';
  END IF;

  -- 2 · Caller identity. auth.uid() is Supabase-provided and returns
  --     NULL when the request is anon or service_role.
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated'
      USING HINT = 'Settings updates require a signed-in user';
  END IF;

  -- 3 · Resolve the user's email by joining to auth.users. Done inside
  --     SECURITY DEFINER so we don't grant anon any direct read on
  --     auth.users.
  SELECT email INTO v_user_email
    FROM auth.users
   WHERE id = v_user_id;

  SELECT contact_email INTO v_tenant_email
    FROM public.tenants
   WHERE id = v_tenant_id;

  -- 4 · Email match check. Lower-cased compare because email is
  --     case-insensitive in practice (RFC 5321 §2.4 says the local
  --     part is technically case-sensitive but it's universally
  --     treated as not). Until the multi-admin tenant_admins table
  --     exists, this single-admin model is the gate.
  IF v_tenant_email IS NULL
     OR v_user_email IS NULL
     OR lower(v_user_email) <> lower(v_tenant_email) THEN
    RAISE EXCEPTION 'not_tenant_admin'
      USING HINT = 'Your email does not match the tenant''s contact_email';
  END IF;

  -- 5 · Perform the update. NULLIF('', '') coerces empty-string inputs
  --     to NULL so COALESCE preserves the existing value instead of
  --     blanking the field; pass NULL or omit a param to leave it
  --     untouched.
  UPDATE public.tenants
     SET display_name = COALESCE(NULLIF(trim(p_display_name), ''), display_name),
         accent_hex   = COALESCE(NULLIF(trim(p_accent_hex),   ''), accent_hex),
         local_number = COALESCE(NULLIF(trim(p_local_number), ''), local_number),
         union_type   = COALESCE(NULLIF(trim(p_union_type),   ''), union_type),
         updated_at   = NOW()
   WHERE id = v_tenant_id
   RETURNING * INTO v_result;

  -- 6 · Audit. jsonb_strip_nulls drops fields the caller didn't change
  --     so the detail shows only what was actually modified.
  v_changed := jsonb_strip_nulls(jsonb_build_object(
    'display_name', p_display_name,
    'accent_hex',   p_accent_hex,
    'local_number', p_local_number,
    'union_type',   p_union_type
  ));

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

REVOKE EXECUTE ON FUNCTION public.update_tenant_settings(text, text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.update_tenant_settings(text, text, text, text) TO authenticated;

COMMENT ON FUNCTION public.update_tenant_settings(text, text, text, text) IS
  'Admin-only mutation of the tenant''s non-sensitive display fields. '
  'SECURITY DEFINER. Requires authenticated user whose email matches the '
  'tenant''s contact_email. Stamps an audit_log row on every successful '
  'update. Raises no_tenant_context / not_authenticated / not_tenant_admin '
  'on the three failure modes.';

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Function exists with expected signature:
--   \df+ public.update_tenant_settings
--
--   -- Unauthenticated call rejected:
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/update_tenant_settings" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Content-Type: application/json" \
--        -d '{"p_display_name":"hack"}'
--   -- Expect: 4xx with code not_authenticated
--
--   -- Authenticated call from non-admin email rejected:
--   -- (Sign in as some@randomemail.com; get the access_token; then …)
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/update_tenant_settings" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Authorization: Bearer $ACCESS_TOKEN" \
--        -H "Content-Type: application/json" \
--        -d '{"p_display_name":"hack"}'
--   -- Expect: 4xx with code not_tenant_admin
--
-- Known follow-ups:
--   · tenant_admins (tenant_id, user_id, role) table for multi-admin
--     tenants. The single-admin email-match model gets us moving but
--     doesn't survive the first locale that needs a steward team.
--   · Logo upload + UPDATE for tenants.logo_url, which requires
--     Supabase Storage bucket policies (separate migration + RPC).
--   · Allowing contact_email rotation under a "confirm with old + new
--     email" double-opt-in pattern.
-- ════════════════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════════════════════
-- ── 0006_tenant_admins
-- ═════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0006 — tenant_admins (multi-admin support)
-- ════════════════════════════════════════════════════════════════════════
-- Replaces the v1 single-admin model (where update_tenant_settings only
-- accepted the user whose email matched tenants.contact_email) with a
-- real membership table linking auth.users to tenants.
--
-- Backward compatibility — the bootstrap problem
-- ─────────────────────────────────────────────────────────────────────
-- Two scenarios this migration has to handle gracefully:
--
--   A · A tenant exists, its contact_email has signed in at least once,
--       so an auth.users row exists. Backfill inserts a tenant_admins
--       row for them. They keep working without interruption.
--
--   B · A tenant exists, its contact_email user has never signed in.
--       Backfill skips them (we can't insert a tenant_admins row
--       referencing a nonexistent auth.users.id). After they sign in
--       for the first time, is_tenant_admin's "bootstrap fallback"
--       (no tenant_admins rows exist yet → fall back to contact_email
--       match) recognises them. The first time they call add_tenant_admin
--       to invite a co-admin, the RPC auto-promotes them into the
--       tenant_admins table so they don't lose access when the bootstrap
--       fallback turns off.
--
-- The bootstrap fallback is intentionally narrow: it only applies when
-- the tenant has zero rows in tenant_admins. Once at least one row
-- exists, contact_email is no longer implicitly an admin — they must
-- be explicitly listed. This is correct: if you've added co-admins,
-- you've moved into "real" multi-admin mode and the email field becomes
-- contact metadata only.
--
-- Function ownership
-- ─────────────────────────────────────────────────────────────────────
-- is_tenant_admin, add_tenant_admin, remove_tenant_admin are all
-- SECURITY DEFINER. They read auth.users (which authenticated users
-- can't read directly), write to tenant_admins (which has no
-- INSERT/UPDATE/DELETE policies for non-service roles), and read
-- public.tenants (where the read is just a sanity check). Lockdown:
-- REVOKE EXECUTE FROM PUBLIC, GRANT EXECUTE TO authenticated.
--
-- Prerequisites: 0001 (tenants), 0002 (get_request_tenant_id),
--                0004 (audit_log), 0005 (update_tenant_settings).
-- ════════════════════════════════════════════════════════════════════════

-- ─── 1 · Table ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.tenant_admins (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES public.tenants(id)  ON DELETE RESTRICT,
  user_id     uuid        NOT NULL REFERENCES auth.users(id)      ON DELETE RESTRICT,
  role        text        NOT NULL DEFAULT 'admin',
  created_at  timestamptz NOT NULL DEFAULT NOW(),
  created_by  uuid        REFERENCES auth.users(id),

  -- The role enum is intentionally tiny for v1. Adding 'viewer' or
  -- 'steward' later means extending the CHECK and updating callers; the
  -- column is here to make that growth path explicit, not because v1
  -- distinguishes roles.
  CONSTRAINT tenant_admins_role_known CHECK (role IN ('admin')),
  CONSTRAINT tenant_admins_unique     UNIQUE (tenant_id, user_id)
);

CREATE INDEX IF NOT EXISTS tenant_admins_user_idx   ON public.tenant_admins (user_id);
CREATE INDEX IF NOT EXISTS tenant_admins_tenant_idx ON public.tenant_admins (tenant_id);


-- ─── 2 · RLS ────────────────────────────────────────────────────────────
ALTER TABLE public.tenant_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_admins FORCE  ROW LEVEL SECURITY;

-- Authenticated users can SELECT admins of the tenant in their x-tenant-id
-- context (so the admin team page can list "who else has access"). They
-- cannot mutate directly — only the add_tenant_admin / remove_tenant_admin
-- RPCs can, both of which check is_tenant_admin first.
DROP POLICY IF EXISTS tenant_admins_read ON public.tenant_admins;
CREATE POLICY tenant_admins_read
  ON public.tenant_admins
  FOR SELECT
  TO authenticated
  USING (tenant_id = public.get_request_tenant_id());


-- ─── 3 · is_tenant_admin(p_tenant_id, p_user_id) → boolean ─────────────
CREATE OR REPLACE FUNCTION public.is_tenant_admin(p_tenant_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_user_email    text;
  v_contact_email text;
  v_has_any       boolean;
BEGIN
  IF p_tenant_id IS NULL OR p_user_id IS NULL THEN
    RETURN false;
  END IF;

  -- Explicit membership wins. Fast path; most authorised calls land here.
  IF EXISTS (
    SELECT 1 FROM public.tenant_admins
     WHERE tenant_id = p_tenant_id AND user_id = p_user_id
  ) THEN
    RETURN true;
  END IF;

  -- Bootstrap fallback: while the tenant has zero rows in tenant_admins,
  -- the contact_email user is implicitly an admin so newly-provisioned
  -- tenants can be operated by the founding email. The moment any
  -- tenant_admins row exists for the tenant, this fallback turns off —
  -- the contact_email user must then be explicitly listed in
  -- tenant_admins. add_tenant_admin handles this transition by
  -- auto-promoting the caller before adding the new admin.
  SELECT EXISTS (
    SELECT 1 FROM public.tenant_admins WHERE tenant_id = p_tenant_id
  ) INTO v_has_any;
  IF v_has_any THEN
    RETURN false;
  END IF;

  SELECT email         INTO v_user_email    FROM auth.users        WHERE id = p_user_id;
  SELECT contact_email INTO v_contact_email FROM public.tenants    WHERE id = p_tenant_id;

  RETURN v_user_email IS NOT NULL
     AND v_contact_email IS NOT NULL
     AND lower(v_user_email) = lower(v_contact_email);
END;
$$;

COMMENT ON FUNCTION public.is_tenant_admin(uuid, uuid) IS
  'True if the user is an admin of the tenant. Checks explicit tenant_admins '
  'membership first; falls back to contact_email match only when the tenant '
  'has zero rows in tenant_admins (bootstrap fallback for newly-provisioned '
  'tenants). SECURITY DEFINER so it can read auth.users.';


-- ─── 4 · add_tenant_admin(p_email) → tenant_admins row ─────────────────
CREATE OR REPLACE FUNCTION public.add_tenant_admin(p_email text)
RETURNS public.tenant_admins
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id    uuid;
  v_caller_id    uuid;
  v_target_id    uuid;
  v_target_email text;
  v_result       public.tenant_admins%ROWTYPE;
  v_was_bootstrap boolean;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context';
  END IF;

  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.is_tenant_admin(v_tenant_id, v_caller_id) THEN
    RAISE EXCEPTION 'not_tenant_admin';
  END IF;

  -- Auto-promote the caller into tenant_admins if they currently qualify
  -- only via the bootstrap fallback. Without this, adding the first
  -- co-admin would activate the "explicit only" mode and immediately
  -- lock the caller out.
  v_was_bootstrap := NOT EXISTS (
    SELECT 1 FROM public.tenant_admins
     WHERE tenant_id = v_tenant_id AND user_id = v_caller_id
  );

  IF v_was_bootstrap THEN
    INSERT INTO public.tenant_admins (tenant_id, user_id, role, created_by)
    VALUES (v_tenant_id, v_caller_id, 'admin', v_caller_id)
    ON CONFLICT (tenant_id, user_id) DO NOTHING;

    INSERT INTO public.audit_log (tenant_id, actor, action, target_type, target_id, detail)
    VALUES (
      v_tenant_id,
      'user:' || v_caller_id::text,
      'tenant_admin_self_promoted',
      'user',
      v_caller_id,
      jsonb_build_object('reason', 'bootstrap_to_explicit')
    );
  END IF;

  -- Validate + look up the target email.
  v_target_email := lower(trim(p_email));
  IF v_target_email = ''
     OR v_target_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'invalid_email';
  END IF;

  SELECT id INTO v_target_id FROM auth.users WHERE lower(email) = v_target_email;
  IF v_target_id IS NULL THEN
    RAISE EXCEPTION 'user_not_signed_in_yet'
      USING HINT = 'Have them sign in via /admin/signin once, then try adding them again';
  END IF;

  -- Insert. If the user is already an admin, this is a no-op (ON CONFLICT)
  -- and we return the existing row.
  INSERT INTO public.tenant_admins (tenant_id, user_id, role, created_by)
  VALUES (v_tenant_id, v_target_id, 'admin', v_caller_id)
  ON CONFLICT (tenant_id, user_id) DO UPDATE
    SET role = EXCLUDED.role           -- no-op but lets RETURNING fire
  RETURNING * INTO v_result;

  INSERT INTO public.audit_log (tenant_id, actor, action, target_type, target_id, detail)
  VALUES (
    v_tenant_id,
    'user:' || v_caller_id::text,
    'tenant_admin_added',
    'user',
    v_target_id,
    jsonb_build_object('email', v_target_email)
  );

  RETURN v_result;
END;
$$;


-- ─── 5 · remove_tenant_admin(p_user_id) → void ─────────────────────────
CREATE OR REPLACE FUNCTION public.remove_tenant_admin(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id uuid;
  v_caller_id uuid;
  v_count     integer;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context';
  END IF;

  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.is_tenant_admin(v_tenant_id, v_caller_id) THEN
    RAISE EXCEPTION 'not_tenant_admin';
  END IF;

  -- Guard against removing the last admin. Once a tenant has explicit
  -- admins, removing them all would brick the tenant (bootstrap fallback
  -- only kicks in when zero rows exist — we'd need to also delete the
  -- last row in the same transaction, which is the DELETE we're rejecting).
  SELECT COUNT(*) INTO v_count
    FROM public.tenant_admins WHERE tenant_id = v_tenant_id;
  IF v_count <= 1 THEN
    RAISE EXCEPTION 'cannot_remove_last_admin'
      USING HINT = 'Add another admin first; you cannot leave a tenant with zero admins';
  END IF;

  DELETE FROM public.tenant_admins
   WHERE tenant_id = v_tenant_id AND user_id = p_user_id;

  INSERT INTO public.audit_log (tenant_id, actor, action, target_type, target_id)
  VALUES (
    v_tenant_id,
    'user:' || v_caller_id::text,
    'tenant_admin_removed',
    'user',
    p_user_id
  );
END;
$$;


-- ─── 6 · Update update_tenant_settings to use is_tenant_admin ──────────
CREATE OR REPLACE FUNCTION public.update_tenant_settings(
  p_display_name text DEFAULT NULL,
  p_accent_hex   text DEFAULT NULL,
  p_local_number text DEFAULT NULL,
  p_union_type   text DEFAULT NULL
)
RETURNS public.tenants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id    uuid;
  v_user_id      uuid;
  v_user_email   text;
  v_result       public.tenants%ROWTYPE;
  v_changed      jsonb;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context';
  END IF;

  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.is_tenant_admin(v_tenant_id, v_user_id) THEN
    RAISE EXCEPTION 'not_tenant_admin'
      USING HINT = 'You are not an admin of this tenant. Ask an existing admin to add you via add_tenant_admin.';
  END IF;

  UPDATE public.tenants
     SET display_name = COALESCE(NULLIF(trim(p_display_name), ''), display_name),
         accent_hex   = COALESCE(NULLIF(trim(p_accent_hex),   ''), accent_hex),
         local_number = COALESCE(NULLIF(trim(p_local_number), ''), local_number),
         union_type   = COALESCE(NULLIF(trim(p_union_type),   ''), union_type),
         updated_at   = NOW()
   WHERE id = v_tenant_id
   RETURNING * INTO v_result;

  v_changed := jsonb_strip_nulls(jsonb_build_object(
    'display_name', p_display_name,
    'accent_hex',   p_accent_hex,
    'local_number', p_local_number,
    'union_type',   p_union_type
  ));

  -- Resolve email for the audit record (best-effort; auth.users may have
  -- been deleted between auth.uid() and now, in which case email is NULL).
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


-- ─── 7 · Backfill from contact_email pairs ─────────────────────────────
-- For each tenant whose contact_email matches an existing auth.users.email,
-- create the tenant_admins row. Idempotent via ON CONFLICT.
INSERT INTO public.tenant_admins (tenant_id, user_id, role, created_by)
SELECT t.id, u.id, 'admin', NULL
  FROM public.tenants t
  JOIN auth.users u ON lower(u.email) = lower(t.contact_email)
ON CONFLICT (tenant_id, user_id) DO NOTHING;


-- ─── 8 · Grants ────────────────────────────────────────────────────────
REVOKE EXECUTE ON FUNCTION public.is_tenant_admin(uuid, uuid)        FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.add_tenant_admin(text)             FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.remove_tenant_admin(uuid)          FROM PUBLIC;

GRANT  EXECUTE ON FUNCTION public.is_tenant_admin(uuid, uuid)        TO authenticated;
GRANT  EXECUTE ON FUNCTION public.add_tenant_admin(text)             TO authenticated;
GRANT  EXECUTE ON FUNCTION public.remove_tenant_admin(uuid)          TO authenticated;


-- ─── 9 · Comments ──────────────────────────────────────────────────────
COMMENT ON TABLE  public.tenant_admins             IS 'Membership: which auth.users are admins of which tenants. v1 has one role (admin); future roles slot into the CHECK.';
COMMENT ON COLUMN public.tenant_admins.created_by  IS 'Who added this admin. NULL for backfilled rows (migration 0006 had no caller context).';
COMMENT ON FUNCTION public.add_tenant_admin(text)  IS 'Invite an existing auth.users by email. Caller must already be a tenant admin. Auto-promotes caller from bootstrap fallback if needed.';
COMMENT ON FUNCTION public.remove_tenant_admin(uuid) IS 'Remove an admin. Refuses if it would leave the tenant with zero admins.';

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- The membership table exists with RLS forced:
--   SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class
--    WHERE relname = 'tenant_admins';
--
--   -- Backfilled rows for tenants whose contact_email had signed in:
--   SELECT t.slug, t.contact_email, u.email, ta.created_by
--     FROM public.tenant_admins ta
--     JOIN public.tenants t ON t.id = ta.tenant_id
--     JOIN auth.users u    ON u.id = ta.user_id
--    ORDER BY t.slug;
--
--   -- Bootstrap fallback still works for tenants whose contact_email
--   -- hasn't signed in yet (they'll show as 0 backfilled rows but
--   -- is_tenant_admin returns true on first sign-in):
--   SELECT t.slug, t.contact_email,
--          EXISTS (SELECT 1 FROM public.tenant_admins WHERE tenant_id = t.id) AS has_explicit
--     FROM public.tenants t
--    ORDER BY t.slug;
--
--   -- Try the new RPC. Authenticated as an existing admin:
--   SELECT public.add_tenant_admin('coworker@example.org');
--   -- → returns the new tenant_admins row OR raises user_not_signed_in_yet
--
-- Known follow-ups:
--   · Admin "team" page UI at /admin/team that lists current admins,
--     supports add (calls add_tenant_admin), and supports remove (calls
--     remove_tenant_admin with the "can't remove yourself if you're last"
--     guard exposed in the UI).
--   · 'viewer' role (read-only) — needs the CHECK constraint extended
--     and is_tenant_admin to distinguish "is admin" from "has access".
--   · Magic-link invitation: when add_tenant_admin raises
--     user_not_signed_in_yet, the UI could trigger a magic-link to the
--     email so the recipient lands on /admin/signin, completes the
--     bootstrap, and the inviter retries the add.
-- ════════════════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════════════════════
-- ── 0007_list_tenant_admins
-- ═════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0007 — list_tenant_admins() RPC
-- ════════════════════════════════════════════════════════════════════════
-- Powers the /admin/team page. Returns the explicit tenant admin rows
-- with the joined email addresses from auth.users.
--
-- Why an RPC instead of a direct PostgREST embed:
--   PostgREST CAN embed FK-related rows, but auth.users is in the auth
--   schema and Supabase doesn't expose it for direct anon/authenticated
--   SELECT. We don't want to expose all auth.users either (that's an
--   enumeration of every signed-in user across the platform). The RPC
--   pattern returns ONLY the admins of the current tenant, joined with
--   their emails, after checking the caller is themselves an admin.
--   Defence in depth: bootstrap admins (bootstrap fallback active) can
--   still see the empty list and self-promote; non-admin signed-in users
--   get not_tenant_admin.
--
-- Includes the creator email via a second join, LEFT so backfilled rows
-- (whose created_by is NULL from migration 0006) come back as NULL
-- rather than disappearing. The UI renders NULL as "—".
--
-- Prerequisites: 0006 (tenant_admins + is_tenant_admin).
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.list_tenant_admins()
RETURNS TABLE (
  user_id          uuid,
  email            text,
  role             text,
  created_at       timestamptz,
  created_by       uuid,
  created_by_email text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id uuid;
  v_user_id   uuid;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context';
  END IF;

  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  -- Bootstrap-fallback admins are valid callers — is_tenant_admin handles
  -- that. The function returns 0 rows for tenants in bootstrap mode (no
  -- explicit admins yet); the UI is expected to detect that and show
  -- the "make me a permanent admin" affordance.
  IF NOT public.is_tenant_admin(v_tenant_id, v_user_id) THEN
    RAISE EXCEPTION 'not_tenant_admin';
  END IF;

  RETURN QUERY
  SELECT
    ta.user_id,
    u.email,
    ta.role,
    ta.created_at,
    ta.created_by,
    c.email AS created_by_email
  FROM public.tenant_admins ta
  JOIN auth.users u ON u.id = ta.user_id
  LEFT JOIN auth.users c ON c.id = ta.created_by
  WHERE ta.tenant_id = v_tenant_id
  ORDER BY ta.created_at ASC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.list_tenant_admins() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.list_tenant_admins() TO authenticated;

COMMENT ON FUNCTION public.list_tenant_admins() IS
  'List explicit tenant admins (joined to auth.users) for the current tenant. '
  'Caller must be an admin (bootstrap-fallback admins included). Returns '
  '(user_id, email, role, created_at, created_by, created_by_email). '
  'Returns zero rows for tenants in bootstrap mode — the UI should '
  'detect that and offer to bootstrap.';

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- As an authenticated admin:
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/list_tenant_admins" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Authorization: Bearer $ACCESS_TOKEN" \
--        -H "Content-Type: application/json" -d '{}'
--   -- Expect: array of {user_id, email, role, created_at, created_by, created_by_email}
--
--   -- As authenticated non-admin:
--   -- Expect: 4xx with code not_tenant_admin
--
--   -- As anon (no Authorization header):
--   -- Expect: 4xx with code not_authenticated
-- ════════════════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════════════════════
-- ── 0008_strict_tenant_admin_rls
-- ═════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0008 — strict tenant_admins-gated RLS
-- ════════════════════════════════════════════════════════════════════════
-- Closes the last RLS gap. Before this migration, any signed-in user
-- visiting a tenant subdomain could read that tenant's members,
-- verifications, dues_collections, and audit_log — RLS only checked
-- tenant_id matched the x-tenant-id header, not whether the caller was
-- actually an admin of the tenant. Now that 0006 + 0007 give us a real
-- membership table (public.tenant_admins) and is_tenant_admin() helper,
-- we can replace "any signed-in user on this subdomain" with "is this
-- caller an admin of this tenant" everywhere.
--
-- The tricky part — and why this migration is bigger than just dropping
-- and recreating policies — is that the public verify and card pages
-- currently rely on anon SELECT on members. Those pages don't sign in
-- (a verifier scanning a QR is the canonical example). Removing anon
-- SELECT on members without giving anon SOMETHING else to call breaks
-- the entire public surface.
--
-- The fix is a narrow SECURITY DEFINER RPC, lookup_member(p_id), that
-- returns exactly one member by id within the request's tenant context,
-- exposing only the display fields. No way to enumerate the roster
-- (the leak that motivated this migration in the first place), no way
-- to cross tenant boundaries (the RPC reads x-tenant-id itself), and
-- the fields it exposes are the same ones already painted publicly on
-- the verify and card pages.
--
-- Three of the existing RPCs (record_verification, check_already_collected,
-- mark_member_paid from 0004) were SECURITY INVOKER and relied on RLS
-- to filter their internal SELECT on members. After this migration RLS
-- on members denies anon, so those internal SELECTs would always fail
-- under INVOKER. Flipping them to DEFINER and adding an explicit
-- tenant_id check in their WHERE clauses preserves the verify flow.
--
-- After this migration:
--
--   anon
--     · CAN  call lookup_member(id) — one row at a time, in-tenant
--     · CAN  call record_verification(id, result)        (DEFINER)
--     · CAN  call check_already_collected(id)            (DEFINER)
--     · CAN  call mark_member_paid(id)                   (DEFINER)
--     · CANNOT  SELECT public.members            (no policy)
--     · CANNOT  SELECT public.verifications      (no policy)
--     · CANNOT  SELECT public.dues_collections   (no policy)
--     · CANNOT  SELECT public.audit_log          (was never allowed)
--
--   authenticated NOT in tenant_admins for the current tenant
--     · same as anon — no admin tables visible at all
--
--   authenticated IN tenant_admins for the current tenant
--     · CAN  SELECT/INSERT/UPDATE/DELETE public.members
--     · CAN  SELECT public.verifications + dues_collections + audit_log
--     · (writes to verifications/dues still go through the RPCs)
--
--   service_role
--     · bypasses everything (provisioning script, migration ops)
--
-- Prerequisites: 0001 (tenants), 0002 (get_request_tenant_id),
--                0004 (verifications + dues_collections + audit_log),
--                0006 (tenant_admins + is_tenant_admin).
-- ════════════════════════════════════════════════════════════════════════

-- ─── 1 · is_request_tenant_admin() helper ──────────────────────────────
-- Convenience wrapper around is_tenant_admin() that pulls the tenant id
-- from the request header and the user id from auth.uid(). Used by every
-- RLS policy below so the policies stay readable.
--
-- SECURITY INVOKER because all the privileged work (reading tenant_admins,
-- joining to auth.users for the bootstrap fallback) already happens
-- inside is_tenant_admin, which IS SECURITY DEFINER. Wrapping a DEFINER
-- in an INVOKER doesn't compromise the bypass — the inner function still
-- runs as its owner.
CREATE OR REPLACE FUNCTION public.is_request_tenant_admin()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT public.is_tenant_admin(public.get_request_tenant_id(), auth.uid());
$$;

REVOKE EXECUTE ON FUNCTION public.is_request_tenant_admin() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.is_request_tenant_admin() TO anon, authenticated;

COMMENT ON FUNCTION public.is_request_tenant_admin() IS
  'Convenience wrapper: is_tenant_admin(get_request_tenant_id(), auth.uid()). '
  'Used by RLS policies on members/verifications/dues_collections/audit_log.';


-- ─── 2 · lookup_member(p_id) — anon-callable single-row member fetch ──
-- The only path anon has to read members after this migration. Returns
-- the same shape card.html and verify.html have always painted; nothing
-- new is exposed publicly that wasn't already visible to anyone who
-- scanned a QR.
--
-- No enumeration: takes a single id parameter, returns at most one row,
-- always filtered to the tenant in the x-tenant-id header. An attacker
-- without a valid member uuid gets nothing useful.
--
-- No cross-tenant: the function reads get_request_tenant_id() itself
-- rather than trusting the caller to filter; sending a member id from
-- local419 with x-tenant-id for local183 returns empty.
CREATE OR REPLACE FUNCTION public.lookup_member(p_id uuid)
RETURNS TABLE (
  id            uuid,
  full_name     text,
  union_name    text,
  local_number  text,
  member_since  date,
  status        text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL OR p_id IS NULL THEN
    RETURN;  -- empty result; anon gets []
  END IF;

  RETURN QUERY
  SELECT m.id, m.full_name, m.union_name, m.local_number, m.member_since, m.status
    FROM public.members m
   WHERE m.id = p_id
     AND m.tenant_id = v_tenant_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.lookup_member(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.lookup_member(uuid) TO anon, authenticated;

COMMENT ON FUNCTION public.lookup_member(uuid) IS
  'Single-row member lookup scoped to the current tenant. SECURITY DEFINER '
  'so anon can call it after 0008 removes their direct SELECT on members. '
  'Returns only the display fields card.html and verify.html paint — never '
  'contact info, internal notes, or anything else added to public.members '
  'in future migrations. Add new fields to this RETURNS TABLE explicitly.';


-- ─── 3 · Re-grant verification RPCs as SECURITY DEFINER ────────────────
-- record_verification, check_already_collected, mark_member_paid were
-- SECURITY INVOKER in 0004 and relied on the anon SELECT policy on
-- members to validate their internal lookups. With anon SELECT on
-- members removed below, those internal SELECTs would always return
-- nothing under INVOKER. Flipping to DEFINER bypasses RLS for the
-- internal checks; the explicit tenant_id filter in each WHERE clause
-- preserves tenant scoping (which was previously done implicitly by RLS).

CREATE OR REPLACE FUNCTION public.record_verification(
  p_member_id uuid,
  p_result    text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RETURN;
  END IF;

  -- Explicit tenant_id filter — RLS no longer scopes for us under DEFINER.
  IF NOT EXISTS (
    SELECT 1 FROM public.members
     WHERE id = p_member_id AND tenant_id = v_tenant_id
  ) THEN
    RETURN;
  END IF;

  BEGIN
    INSERT INTO public.verifications (tenant_id, member_id, result)
    VALUES (v_tenant_id, p_member_id, p_result);
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- logging never breaks the verify flow
  END;
END;
$$;


CREATE OR REPLACE FUNCTION public.check_already_collected(p_member_id uuid)
RETURNS TABLE (already boolean, paid_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_collected_at timestamptz;
BEGIN
  -- Already tenant-scoped via the WHERE clause; this function didn't
  -- need an internal members check. Flip to DEFINER just for
  -- consistency with the other two and because dues_collections RLS
  -- below denies direct anon SELECT.
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


CREATE OR REPLACE FUNCTION public.mark_member_paid(p_member_id uuid)
RETURNS TABLE (was_already_paid boolean, paid_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
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

  -- Explicit tenant_id filter (RLS no longer scopes under DEFINER).
  IF NOT EXISTS (
    SELECT 1 FROM public.members
     WHERE id = p_member_id AND tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'member_not_found_in_tenant'
      USING HINT = 'Member UUID does not exist in this tenant';
  END IF;

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

-- Existing grants from 0004 are preserved by CREATE OR REPLACE; no
-- re-grant needed. The functions are still callable by anon + authenticated.


-- ─── 4 · members RLS — tighten ─────────────────────────────────────────
-- Drop everything from 0002 and rebuild. anon gets no policies (must use
-- lookup_member RPC instead). authenticated gets four CRUD policies all
-- gated on is_request_tenant_admin(). FORCE RLS stays on from 0002.

DROP POLICY IF EXISTS members_tenant_isolated_read   ON public.members;
DROP POLICY IF EXISTS members_tenant_isolated_insert ON public.members;
DROP POLICY IF EXISTS members_tenant_isolated_update ON public.members;
DROP POLICY IF EXISTS members_tenant_isolated_delete ON public.members;

CREATE POLICY members_admin_read
  ON public.members
  FOR SELECT
  TO authenticated
  USING (public.is_request_tenant_admin());

CREATE POLICY members_admin_insert
  ON public.members
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_request_tenant_admin()
    AND tenant_id = public.get_request_tenant_id()
  );

CREATE POLICY members_admin_update
  ON public.members
  FOR UPDATE
  TO authenticated
  USING (public.is_request_tenant_admin())
  WITH CHECK (
    public.is_request_tenant_admin()
    AND tenant_id = public.get_request_tenant_id()
  );

CREATE POLICY members_admin_delete
  ON public.members
  FOR DELETE
  TO authenticated
  USING (public.is_request_tenant_admin());


-- ─── 5 · verifications RLS — tighten ───────────────────────────────────
-- The anon INSERT policy from 0004 was dead code (verify.html always
-- called record_verification RPC, never direct INSERT). Drop it.
-- Direct authenticated SELECT now requires admin membership.

DROP POLICY IF EXISTS verifications_tenant_isolated_read   ON public.verifications;
DROP POLICY IF EXISTS verifications_tenant_isolated_insert ON public.verifications;

CREATE POLICY verifications_admin_read
  ON public.verifications
  FOR SELECT
  TO authenticated
  USING (public.is_request_tenant_admin());

-- No INSERT policy. Writes only via record_verification RPC (DEFINER).
-- No UPDATE/DELETE policies. Append-only invariant from 0004 holds.


-- ─── 6 · dues_collections RLS — tighten ────────────────────────────────
DROP POLICY IF EXISTS dues_tenant_isolated_read   ON public.dues_collections;
DROP POLICY IF EXISTS dues_tenant_isolated_insert ON public.dues_collections;

CREATE POLICY dues_admin_read
  ON public.dues_collections
  FOR SELECT
  TO authenticated
  USING (public.is_request_tenant_admin());

-- No INSERT policy. Writes only via mark_member_paid RPC (DEFINER).


-- ─── 7 · audit_log RLS — tighten ───────────────────────────────────────
DROP POLICY IF EXISTS audit_log_authenticated_read ON public.audit_log;

CREATE POLICY audit_log_admin_read
  ON public.audit_log
  FOR SELECT
  TO authenticated
  USING (public.is_request_tenant_admin());


-- ─── 8 · Comments ──────────────────────────────────────────────────────
COMMENT ON POLICY members_admin_read       ON public.members           IS 'Tightened in 0008: requires tenant_admins membership (or bootstrap). anon must use lookup_member RPC.';
COMMENT ON POLICY verifications_admin_read ON public.verifications     IS 'Tightened in 0008: requires tenant_admins membership.';
COMMENT ON POLICY dues_admin_read          ON public.dues_collections  IS 'Tightened in 0008: requires tenant_admins membership.';
COMMENT ON POLICY audit_log_admin_read     ON public.audit_log         IS 'Tightened in 0008: requires tenant_admins membership.';

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Anon enumeration of members should now return empty even WITH the
--   -- right tenant header. This is the leak this migration closes:
--   curl -s "$SUPABASE_URL/rest/v1/members?select=id" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID"
--   -- Expect: []
--
--   -- Anon single-row lookup via the new RPC should work:
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/lookup_member" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Content-Type: application/json" \
--        -d '{"p_id":"550bc413-53db-4f83-98e4-7c5c44d721d0"}'
--   -- Expect: [{"id":"...","full_name":"...","status":"active",...}]
--
--   -- Wrong tenant: empty even with a valid member id:
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/lookup_member" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: 00000000-0000-0000-0000-000000000000" \
--        -H "Content-Type: application/json" \
--        -d '{"p_id":"550bc413-53db-4f83-98e4-7c5c44d721d0"}'
--   -- Expect: []
--
--   -- Authenticated NON-admin should see empty members list (this is the
--   -- gap this migration closes):
--   -- (Sign in as some random email that is NOT in tenant_admins, then…)
--   curl -s "$SUPABASE_URL/rest/v1/members?select=id" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Authorization: Bearer $RANDOM_USER_TOKEN"
--   -- Expect: []
--
--   -- Authenticated admin sees the full list:
--   curl -s "$SUPABASE_URL/rest/v1/members?select=id" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Authorization: Bearer $ADMIN_TOKEN"
--   -- Expect: full list
--
--   -- verify.html flow end-to-end (anon → RPCs):
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/record_verification" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Content-Type: application/json" \
--        -d '{"p_member_id":"550bc413-53db-4f83-98e4-7c5c44d721d0","p_result":"verified"}'
--   -- Expect: 204 (function returns void)
--
-- Known follow-ups (none blocking, all separate slices):
--
--   · A `lookup_recent_verifications(p_member_id)` RPC if any public
--     surface ever needs to display a member's recent verification
--     history without an admin session.
--
--   · Splitting authenticated INSERT/UPDATE/DELETE on members further
--     into role-based grants once tenant_admins has a 'viewer' role.
--
--   · Tightening the lookup_member return shape: today it returns
--     union_name + local_number from public.members (denormalised from
--     tenants). Once those columns are dropped (the follow-up flagged
--     in 0002), the RPC will JOIN public.tenants to derive them.
-- ════════════════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════════════════════
-- ── 0009_admin_member_create
-- ═════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0009 — admin_add_member + admin_add_members_bulk
-- ════════════════════════════════════════════════════════════════════════
-- Adds the two RPCs the admin app calls to create members: a single-row
-- insert from /admin/member-new, and a bulk import from /admin/import
-- (CSV upload).
--
-- Why RPCs instead of direct INSERT under the 0008 admin RLS:
--   Migration 0008 left an authenticated INSERT policy on members that
--   would technically accept the create. But going through an RPC:
--     · Centralises validation (full_name required, status enum, …)
--     · Writes a consistent audit_log entry every time
--     · Lets the bulk path catch per-row failures without rolling back
--       the successful inserts in the same call (BEGIN/EXCEPTION inside
--       a function creates an implicit savepoint)
--     · Defaults denormalised columns (union_name, local_number) from
--       the tenant row so an admin importing a CSV doesn't need to
--       know to repeat their own union name on every line
--
-- Bulk batching: the function caps at 1000 rows per call. Larger
-- imports are split client-side. Each row in the call is wrapped in
-- its own savepoint via BEGIN/EXCEPTION so a malformed row is reported
-- as { success: false, error: … } without aborting the rest.
--
-- Audit:
--   admin_add_member         → 'member_added'         per row, target = new member uuid
--   admin_add_members_bulk   → 'members_bulk_imported' once, with {requested, inserted, failed}
--
-- Prerequisites: 0001 (tenants), 0002 (members + get_request_tenant_id),
--                0004 (audit_log), 0006 (tenant_admins + is_tenant_admin).
-- ════════════════════════════════════════════════════════════════════════

-- ─── 1 · admin_add_member ──────────────────────────────────────────────
-- Single-row insert. Returns the full members row.

CREATE OR REPLACE FUNCTION public.admin_add_member(
  p_full_name    text,
  p_status       text DEFAULT 'active',
  p_member_since date DEFAULT NULL,
  p_union_name   text DEFAULT NULL,   -- override; defaults to tenant.display_name
  p_local_number text DEFAULT NULL    -- override; defaults to tenant.local_number
)
RETURNS public.members
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id  uuid;
  v_user_id    uuid;
  v_tenant     public.tenants%ROWTYPE;
  v_full_name  text;
  v_status     text;
  v_result     public.members%ROWTYPE;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context';
  END IF;

  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.is_tenant_admin(v_tenant_id, v_user_id) THEN
    RAISE EXCEPTION 'not_tenant_admin';
  END IF;

  -- Validate
  v_full_name := trim(COALESCE(p_full_name, ''));
  v_status    := COALESCE(NULLIF(trim(p_status), ''), 'active');

  IF v_full_name = '' THEN
    RAISE EXCEPTION 'full_name_required';
  END IF;

  -- Tenant row for denormalised defaults.
  SELECT * INTO v_tenant FROM public.tenants WHERE id = v_tenant_id;

  INSERT INTO public.members (
    tenant_id, full_name, status, member_since, union_name, local_number
  )
  VALUES (
    v_tenant_id,
    v_full_name,
    v_status,
    p_member_since,
    COALESCE(NULLIF(trim(p_union_name),   ''), v_tenant.display_name),
    COALESCE(NULLIF(trim(p_local_number), ''), v_tenant.local_number)
  )
  RETURNING * INTO v_result;

  INSERT INTO public.audit_log (
    tenant_id, actor, action, target_type, target_id, detail
  )
  VALUES (
    v_tenant_id,
    'user:' || v_user_id::text,
    'member_added',
    'member',
    v_result.id,
    jsonb_build_object(
      'full_name', v_result.full_name,
      'status',    v_result.status
    )
  );

  RETURN v_result;
END;
$$;


-- ─── 2 · admin_add_members_bulk ────────────────────────────────────────
-- Batch insert. Takes a jsonb array of member objects, attempts each row
-- in its own implicit savepoint (BEGIN/EXCEPTION), returns a per-row
-- result table so the UI can report exactly which CSV rows failed.
--
-- Schema for each input object (extra keys ignored):
--   { "full_name":    "Jane Doe",         (required, non-empty after trim)
--     "status":       "active",           (optional, default 'active')
--     "member_since": "2019-04-12",       (optional, ISO date or null)
--     "union_name":   "Override Union",   (optional, defaults to tenant)
--     "local_number": "B-9"               (optional, defaults to tenant) }
--
-- Caps at 1000 rows per call. The /admin/import page splits larger CSVs
-- into 500-row batches client-side and stitches the results back together.

CREATE OR REPLACE FUNCTION public.admin_add_members_bulk(p_members jsonb)
RETURNS TABLE (
  row_index  int,
  success    boolean,
  member_id  uuid,
  error_code text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id     uuid;
  v_user_id       uuid;
  v_tenant        public.tenants%ROWTYPE;
  v_row           jsonb;
  v_idx           int;
  v_count         int;
  v_inserted      uuid;
  v_full_name     text;
  v_status        text;
  v_member_since  date;
  v_success_count int := 0;
  v_fail_count    int := 0;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context';
  END IF;

  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.is_tenant_admin(v_tenant_id, v_user_id) THEN
    RAISE EXCEPTION 'not_tenant_admin';
  END IF;

  IF jsonb_typeof(p_members) <> 'array' THEN
    RAISE EXCEPTION 'expected_array'
      USING HINT = 'p_members must be a JSON array of member objects';
  END IF;

  v_count := jsonb_array_length(p_members);
  IF v_count = 0 THEN
    RETURN;  -- empty input, no insert, no audit
  END IF;

  IF v_count > 1000 THEN
    RAISE EXCEPTION 'batch_too_large'
      USING HINT = 'Maximum 1000 members per call; the UI splits larger CSVs into 500-row batches';
  END IF;

  -- Tenant row for denormalised defaults — fetched once, reused for every row.
  SELECT * INTO v_tenant FROM public.tenants WHERE id = v_tenant_id;

  FOR v_idx IN 0 .. v_count - 1 LOOP
    BEGIN
      v_row := p_members -> v_idx;

      v_full_name := trim(COALESCE(v_row->>'full_name', ''));
      v_status    := COALESCE(NULLIF(trim(v_row->>'status'), ''), 'active');
      v_member_since := NULLIF(v_row->>'member_since', '')::date;

      IF v_full_name = '' THEN
        RAISE EXCEPTION 'full_name_required';
      END IF;

      INSERT INTO public.members (
        tenant_id, full_name, status, member_since, union_name, local_number
      )
      VALUES (
        v_tenant_id,
        v_full_name,
        v_status,
        v_member_since,
        COALESCE(NULLIF(trim(v_row->>'union_name'),   ''), v_tenant.display_name),
        COALESCE(NULLIF(trim(v_row->>'local_number'), ''), v_tenant.local_number)
      )
      RETURNING id INTO v_inserted;

      v_success_count := v_success_count + 1;
      RETURN QUERY SELECT v_idx, true, v_inserted, NULL::text;

    EXCEPTION WHEN OTHERS THEN
      -- Map common Postgres error codes to friendly strings the UI can
      -- translate. Anything we don't recognise falls through to SQLERRM.
      v_fail_count := v_fail_count + 1;
      RETURN QUERY SELECT v_idx, false, NULL::uuid,
        CASE
          WHEN SQLERRM = 'full_name_required' THEN 'full_name_required'
          WHEN SQLSTATE = '23502' THEN 'missing_required_field'
          WHEN SQLSTATE = '23514' THEN 'invalid_value'
          WHEN SQLSTATE = '23505' THEN 'duplicate'
          WHEN SQLSTATE IN ('22007', '22008') THEN 'invalid_date'
          ELSE SQLERRM
        END;
    END;
  END LOOP;

  -- One audit row per bulk operation, not per member — the audit log
  -- would balloon otherwise. The detail JSON captures the per-call
  -- shape so reports can reconstruct the import event.
  INSERT INTO public.audit_log (
    tenant_id, actor, action, target_type, detail
  )
  VALUES (
    v_tenant_id,
    'user:' || v_user_id::text,
    'members_bulk_imported',
    'member',
    jsonb_build_object(
      'requested', v_count,
      'inserted',  v_success_count,
      'failed',    v_fail_count
    )
  );
END;
$$;


-- ─── 3 · Grants ────────────────────────────────────────────────────────
REVOKE EXECUTE ON FUNCTION public.admin_add_member(text, text, date, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_add_members_bulk(jsonb)                  FROM PUBLIC;

GRANT  EXECUTE ON FUNCTION public.admin_add_member(text, text, date, text, text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.admin_add_members_bulk(jsonb)                  TO authenticated;


-- ─── 4 · Comments ──────────────────────────────────────────────────────
COMMENT ON FUNCTION public.admin_add_member(text, text, date, text, text) IS
  'Single-row member insert with audit. SECURITY DEFINER. Caller must be a tenant admin. '
  'union_name + local_number default to the tenant row when omitted.';

COMMENT ON FUNCTION public.admin_add_members_bulk(jsonb) IS
  'Batch member insert. SECURITY DEFINER. Up to 1000 rows per call. Per-row '
  'savepoints so one bad row does not roll back the rest. Returns a result '
  'table the UI can map back to CSV rows by row_index.';

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Single add (authenticated admin):
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/admin_add_member" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Authorization: Bearer $ADMIN_TOKEN" \
--        -H "Content-Type: application/json" \
--        -d '{"p_full_name":"Smoke Test","p_status":"active"}'
--   -- → returns the new member row
--
--   -- Bulk with one good + one bad row:
--   curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/admin_add_members_bulk" \
--        -H "apikey: $SUPABASE_ANON_KEY" \
--        -H "x-tenant-id: $DEMO_UUID" \
--        -H "Authorization: Bearer $ADMIN_TOKEN" \
--        -H "Content-Type: application/json" \
--        -d '{"p_members":[
--             {"full_name":"Good Row","status":"active"},
--             {"full_name":"","status":"active"}
--           ]}'
--   -- → [{"row_index":0,"success":true,"member_id":"...","error_code":null},
--   --    {"row_index":1,"success":false,"member_id":null,"error_code":"full_name_required"}]
--
--   -- Non-admin attempt:
--   curl ... -d '{"p_full_name":"Hack"}'
--   -- → 4xx with code not_tenant_admin
--
-- Known follow-ups:
--   · Idempotency key on bulk import — if a network hiccup causes the
--     UI to retry, today we'd double-insert. Future: add a uuid in each
--     row that the RPC dedups against a recent-imports cache.
--   · Server-side CSV parsing via Edge Function + Storage upload for
--     huge imports (10k+ rows) instead of client-side batching.
--   · UPDATE-on-conflict semantics for re-running an import: today
--     every row is INSERT, so re-import duplicates. Future: optional
--     ON CONFLICT (tenant_id, some-external-id) DO UPDATE.
-- ════════════════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════════════════════
-- ── 0010_tenant_dues_cycle
-- ═════════════════════════════════════════════════════════════════════════

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


-- ═════════════════════════════════════════════════════════════════════════
-- ── 0011_tenant_logo
-- ═════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0011 — tenant logo upload
-- ════════════════════════════════════════════════════════════════════════
-- Closes the last admin surface: tenants can upload a logo that paints
-- on the member card (replacing the canonical platform mark). Three
-- pieces:
--
--   1. Supabase Storage bucket `tenant-assets` (public read, admin
--      write). Path convention: <tenant_id>/logo.<ext>.
--   2. RLS policies on storage.objects that gate writes by
--      is_tenant_admin against the path's first folder (the tenant id).
--   3. SECURITY DEFINER RPC public.set_tenant_logo(p_url) that updates
--      tenants.logo_url with an audit entry. Removing a logo is a NULL
--      url through the same RPC.
--
-- Why a separate RPC instead of folding logo_url into update_tenant_settings:
--
--   The logo is a distinct UX flow (file upload, preview, in-place
--   replace) with its own audit semantics: 'tenant_logo_updated' vs
--   'tenant_logo_removed' tells the audit reader what actually
--   happened. Stuffing logo_url into update_tenant_settings would
--   bury that signal in a generic 'tenant_settings_updated' row.
--
-- Why the bucket is public:
--
--   Logos render on the member card (which anon visitors hit). A
--   public bucket lets the browser fetch the image with one round
--   trip and no Authorization plumbing. The tenant_id in the path
--   is also not secret (it's already in the x-tenant-* response
--   headers the middleware sets). Read access leaks nothing beyond
--   what the card itself already shows.
--
-- Prerequisites: 0001 (tenants), 0006 (is_tenant_admin), 0008 (the
--                strict-RLS world where authenticated admin writes
--                are gated by tenant membership). The migration
--                assumes the Supabase storage extension is installed
--                (it is in every Supabase project by default).
-- ════════════════════════════════════════════════════════════════════════

-- ─── 1 · Storage bucket ────────────────────────────────────────────────
-- Idempotent insert. ON CONFLICT DO UPDATE lets us evolve the size
-- limit + allowed types in a future migration by re-running this block.
--
-- Size limit: 5 MiB. SVG is allowed for crisp logos.

INSERT INTO storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
)
VALUES (
  'tenant-assets',
  'tenant-assets',
  true,
  5242880,
  ARRAY['image/png', 'image/jpeg', 'image/svg+xml', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;


-- ─── 2 · Storage RLS policies ──────────────────────────────────────────
-- storage.objects already has RLS enabled by Supabase. We add four
-- policies scoped to bucket_id = 'tenant-assets'.
--
-- Public read: anon + authenticated can SELECT any object in the bucket.
-- Required because the card page renders the logo without auth. The
-- bucket is also marked public above so the /object/public/ URL pattern
-- works without an Authorization header.
--
-- Admin INSERT/UPDATE/DELETE: caller must be a tenant_admin of the
-- tenant whose UUID matches the first folder of the object path. The
-- CASE guard prevents the ::uuid cast from raising when the path
-- doesn't start with a UUID-shaped string — is_tenant_admin treats
-- NULL tenant_id as false, so non-UUID paths are silently denied.

DROP POLICY IF EXISTS tenant_assets_public_read ON storage.objects;
CREATE POLICY tenant_assets_public_read
  ON storage.objects
  FOR SELECT
  TO anon, authenticated
  USING (bucket_id = 'tenant-assets');

DROP POLICY IF EXISTS tenant_assets_admin_insert ON storage.objects;
CREATE POLICY tenant_assets_admin_insert
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'tenant-assets'
    AND public.is_tenant_admin(
      CASE WHEN split_part(name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           THEN split_part(name, '/', 1)::uuid
           ELSE NULL END,
      auth.uid()
    )
  );

DROP POLICY IF EXISTS tenant_assets_admin_update ON storage.objects;
CREATE POLICY tenant_assets_admin_update
  ON storage.objects
  FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'tenant-assets'
    AND public.is_tenant_admin(
      CASE WHEN split_part(name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           THEN split_part(name, '/', 1)::uuid
           ELSE NULL END,
      auth.uid()
    )
  );

DROP POLICY IF EXISTS tenant_assets_admin_delete ON storage.objects;
CREATE POLICY tenant_assets_admin_delete
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'tenant-assets'
    AND public.is_tenant_admin(
      CASE WHEN split_part(name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           THEN split_part(name, '/', 1)::uuid
           ELSE NULL END,
      auth.uid()
    )
  );


-- ─── 3 · set_tenant_logo(p_url) RPC ────────────────────────────────────
-- The DB side of the upload flow. Client:
--   1. Calls Storage REST to upload bytes to <tenant_id>/logo.<ext>.
--   2. Constructs the public URL.
--   3. Calls this RPC with the URL.
-- Removing a logo is the same RPC with p_url = NULL (or empty).
--
-- Validates the URL shape (must be http(s)) as cheap defence — the
-- real authorisation is the is_tenant_admin check. The actual file
-- bytes are NOT validated here; Storage RLS + bucket allowed_mime_types
-- enforce that at upload time.
--
-- Audit action distinguishes set vs remove so the audit log reader
-- doesn't have to inspect the detail JSON to know what happened.

CREATE OR REPLACE FUNCTION public.set_tenant_logo(p_url text DEFAULT NULL)
RETURNS public.tenants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id   uuid;
  v_user_id     uuid;
  v_user_email  text;
  v_old_url     text;
  v_new_url     text;
  v_result      public.tenants%ROWTYPE;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context';
  END IF;

  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.is_tenant_admin(v_tenant_id, v_user_id) THEN
    RAISE EXCEPTION 'not_tenant_admin'
      USING HINT = 'You are not an admin of this tenant';
  END IF;

  v_new_url := NULLIF(trim(p_url), '');

  -- Cheap URL shape check. We don't enforce a specific origin because
  -- a tenant might host their logo elsewhere down the road; the real
  -- guard is admin-only write.
  IF v_new_url IS NOT NULL AND v_new_url !~* '^https?://' THEN
    RAISE EXCEPTION 'invalid_url'
      USING HINT = 'logo_url must start with http:// or https://';
  END IF;

  SELECT logo_url INTO v_old_url FROM public.tenants WHERE id = v_tenant_id;

  UPDATE public.tenants
     SET logo_url   = v_new_url,
         updated_at = NOW()
   WHERE id = v_tenant_id
   RETURNING * INTO v_result;

  SELECT email INTO v_user_email FROM auth.users WHERE id = v_user_id;

  INSERT INTO public.audit_log (
    tenant_id, actor, action, target_type, target_id, detail
  )
  VALUES (
    v_tenant_id,
    'user:' || v_user_id::text,
    CASE WHEN v_new_url IS NULL THEN 'tenant_logo_removed'
                                ELSE 'tenant_logo_updated' END,
    'tenant',
    v_tenant_id,
    jsonb_build_object(
      'actor_email', v_user_email,
      'old_url',     v_old_url,
      'new_url',     v_new_url
    )
  );

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_tenant_logo(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.set_tenant_logo(text) TO authenticated;

COMMENT ON FUNCTION public.set_tenant_logo(text) IS
  'Updates tenants.logo_url. Admin-only via is_tenant_admin. NULL or '
  'empty p_url clears the logo (action ''tenant_logo_removed''); any '
  'http(s) URL sets it (action ''tenant_logo_updated''). Storage file '
  'cleanup is the client''s job.';

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Bucket exists with the right limits:
--   SELECT id, public, file_size_limit, allowed_mime_types
--     FROM storage.buckets WHERE id = 'tenant-assets';
--
--   -- Four policies on storage.objects scoped to the bucket:
--   SELECT polname FROM pg_policy
--    WHERE polrelid = 'storage.objects'::regclass
--      AND polname LIKE 'tenant_assets_%'
--    ORDER BY polname;
--
--   -- As an authenticated admin: upload a logo via Storage REST.
--   curl -X POST \
--     "$SUPABASE_URL/storage/v1/object/tenant-assets/$DEMO_UUID/logo.png" \
--     -H "apikey: $SUPABASE_ANON_KEY" \
--     -H "Authorization: Bearer $ADMIN_TOKEN" \
--     -H "Content-Type: image/png" \
--     -H "x-upsert: true" \
--     --data-binary @logo.png
--
--   -- Then set the URL on the tenant row:
--   curl -X POST "$SUPABASE_URL/rest/v1/rpc/set_tenant_logo" \
--     -H "apikey: $SUPABASE_ANON_KEY" \
--     -H "x-tenant-id: $DEMO_UUID" \
--     -H "Authorization: Bearer $ADMIN_TOKEN" \
--     -H "Content-Type: application/json" \
--     -d "{\"p_url\":\"$SUPABASE_URL/storage/v1/object/public/tenant-assets/$DEMO_UUID/logo.png\"}"
--
--   -- Non-admin upload attempt is rejected by storage RLS:
--   -- (same POST as above with $RANDOM_USER_TOKEN → 4xx)
--
--   -- Cross-tenant attempt (admin of tenant A uploading to tenant B's
--   -- path): also rejected — is_tenant_admin returns false because
--   -- the path's first folder is tenant B's id.
--
-- Known follow-ups (not blocking):
--   · Image dimension validation server-side (today: client validates
--     mime + size only; bad-aspect logos render poorly but upload OK).
--   · Logo CDN cache invalidation when re-uploading to the same path
--     — handled today by the client appending ?v=<timestamp> to the
--     URL it stores.
--   · Webhook / scheduled cleanup of orphaned Storage objects when a
--     tenant is archived — today they linger.
-- ════════════════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════════════════════
-- ── 0012_public_roster
-- ═════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0012 — public.public_roster() RPC
-- ════════════════════════════════════════════════════════════════════════
-- Restores the marketing site's "live roster" strip. Same problem as
-- the public_stats regression that 0003 fixed — when 0008 tightened
-- members RLS to require tenant_admins, anon visitors to the apex
-- (no tenant context, no admin session) could no longer SELECT any
-- members. The js/live.js fetchRoster hit /rest/v1/members?id=in.(…)
-- and got [] back; the page degraded to whatever static HTML was in
-- the [data-live-roster] container.
--
-- The fix mirrors public_stats: a SECURITY DEFINER RPC that bypasses
-- RLS to read members, returning ONLY the demo tenant's members
-- (which are explicitly seeded as showcase data — see seed.sql) and
-- ONLY the display fields the marketing-site strip paints.
--
-- Security tripwires defused (same set public_stats handles):
--
--   1. SECURITY DEFINER lets the function see members rows that the
--      caller cannot. The body is scoped so anon only ever gets the
--      demo tenant's members — never any real union's roster.
--
--   2. SET search_path = public, pg_temp pins lookups to the trusted
--      schema; a malicious shadow view in another schema can't
--      intercept the SELECT.
--
--   3. REVOKE EXECUTE FROM PUBLIC + GRANT to anon, authenticated.
--      service_role bypasses RLS and EXECUTE grants entirely.
--
--   4. STABLE + PARALLEL SAFE — function is read-only, deterministic
--      within a statement.
--
--   5. Result capped at 50 rows — prevents anyone from enumerating
--      the full demo roster via a runaway p_limit. The marketing
--      strip only renders ~3 rows anyway.
--
-- Prerequisites: 0001 (tenants), 0002 (members + tenant_id).
-- Tolerates 0002 not being applied (members table missing → returns
-- empty rather than raising).
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.public_roster(p_limit int DEFAULT 10)
RETURNS TABLE (
  id            uuid,
  full_name     text,
  status        text,
  member_since  date
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
STABLE
PARALLEL SAFE
AS $$
DECLARE
  v_demo_tenant_id uuid;
  v_cap            int;
BEGIN
  -- Clamp the requested limit between 1 and 50. A pathological request
  -- with p_limit = 100000 can't enumerate the demo tenant's full roster;
  -- a missing or negative value still returns something useful.
  v_cap := GREATEST(1, LEAST(COALESCE(p_limit, 10), 50));

  -- Resolve the demo tenant. If it doesn't exist (very early scaffold,
  -- before seed.sql ran) or has been archived, return empty silently —
  -- a failed marketing-page widget should never raise.
  SELECT t.id INTO v_demo_tenant_id
    FROM public.tenants t
   WHERE t.slug = 'demo' AND t.status = 'active'
   LIMIT 1;

  IF v_demo_tenant_id IS NULL THEN
    RETURN;
  END IF;

  -- Order for visual stability: status priority (active → inactive →
  -- suspended → pending → other), then alphabetical. The marketing
  -- strip renders rows in this exact order without further sorting.
  BEGIN
    RETURN QUERY
      SELECT m.id, m.full_name, m.status, m.member_since
        FROM public.members m
       WHERE m.tenant_id = v_demo_tenant_id
       ORDER BY
         CASE m.status
           WHEN 'active'    THEN 0
           WHEN 'inactive'  THEN 1
           WHEN 'suspended' THEN 2
           WHEN 'pending'   THEN 3
           ELSE              4
         END,
         m.full_name ASC
       LIMIT v_cap;
  EXCEPTION WHEN undefined_table THEN
    -- members table doesn't exist yet (pre-0002). Same silent-empty
    -- pattern as public_stats uses for verifications.
    RETURN;
  END;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.public_roster(int) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.public_roster(int) TO anon, authenticated;

COMMENT ON FUNCTION public.public_roster(int) IS
  'Returns a curated list of demo tenant members for the marketing site''s '
  'live-roster strip. SECURITY DEFINER so anon can call it after 0008 '
  'removed direct SELECT on members. Returns ONLY id + full_name + status '
  '+ member_since for the ''demo'' tenant — never other tenants, never '
  'fields like email or notes. Capped at 50 rows. The demo tenant''s '
  'members are showcase data by design (seed.sql).';

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Anon call:
--   curl -s "$SUPABASE_URL/rest/v1/rpc/public_roster" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--   -- Expect: [{"id":"550bc413…","full_name":"Demo Member · Active",
--   --           "status":"active","member_since":null}, …]
--
--   -- With limit:
--   curl -s "$SUPABASE_URL/rest/v1/rpc/public_roster?p_limit=2" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--
--   -- Pathological limit gets clamped:
--   curl -s "$SUPABASE_URL/rest/v1/rpc/public_roster?p_limit=99999" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--   -- Expect: still capped at 50 rows
--
--   -- Cross-check: anon STILL can't read members directly (0008 lock
--   -- intact, RPC is the only narrow window):
--   curl -s "$SUPABASE_URL/rest/v1/members?select=id" \
--        -H "apikey: $SUPABASE_ANON_KEY"
--   -- Expect: []
--
-- Known follow-ups:
--   · A `showcase` flag on members so the marketing strip can include
--     curated rows from non-demo tenants who opt in (e.g., an early
--     real local that's happy to be featured).
--   · A materialized view backing this RPC if the marketing site ever
--     becomes high-traffic enough that the per-call query matters.
-- ════════════════════════════════════════════════════════════════════════

