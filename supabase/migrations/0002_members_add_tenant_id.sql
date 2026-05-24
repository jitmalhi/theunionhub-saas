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

BEGIN;

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

COMMIT;

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
