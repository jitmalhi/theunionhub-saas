-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · supabase/seed.sql
-- ════════════════════════════════════════════════════════════════════════
-- Runs automatically on `supabase db reset` (dev only). Vercel + production
-- never invoke this file. It is safe to run repeatedly: every statement
-- either upserts or is wrapped in an existence guard.
--
-- Purpose:
--   1. Land a 'demo' tenant so demo.theunionhub.com / demo.lvh.me:3000
--      stops failing-open in the middleware and starts rendering with
--      real x-tenant-{id,name,accent} headers.
--   2. Bind the three carry-over prototype member UUIDs to the demo
--      tenant so card.html / verify.html resolve them under tenant-
--      scoped queries.
--
-- Prerequisites:
--   · Migration 0001 applied   →  Section A runs.
--   · Migration 0002 applied   →  Section B also runs.
--   · Neither applied          →  This file errors out on Section A.
--
-- The three demo UUIDs originate in the prototype's js/live.js and are
-- referenced from card.html?id=… and verify.html?id=… for the live
-- demo links on the marketing site. Changing them here means updating
-- those references too — keep this file and js/live.js in sync.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─── A · Demo tenant ─────────────────────────────────────────────────────
-- Authoritative upsert: every run brings the demo tenant back to a
-- known-good state. The id column is intentionally NOT pinned to a fixed
-- uuid — Postgres assigns one on first insert, subsequent runs preserve
-- it via the slug uniqueness constraint. Downstream code (and Section B
-- below) looks it up by slug, never by literal id.

INSERT INTO public.tenants (
  slug,
  display_name,
  local_number,
  union_type,
  accent_hex,
  contact_email,
  status
)
VALUES (
  'demo',
  'The Union Hub Demo Local',
  '000',
  'DEMO',
  '#0F6E56',
  'demo@theunionhub.com',
  'active'
)
ON CONFLICT (slug) DO UPDATE
  SET display_name  = EXCLUDED.display_name,
      local_number  = EXCLUDED.local_number,
      union_type    = EXCLUDED.union_type,
      accent_hex    = EXCLUDED.accent_hex,
      contact_email = EXCLUDED.contact_email,
      status        = EXCLUDED.status;

DO $$
DECLARE
  v_tenant_id uuid;
BEGIN
  SELECT id INTO v_tenant_id FROM public.tenants WHERE slug = 'demo';
  RAISE NOTICE '[seed] demo tenant: % (id=%)', 'demo', v_tenant_id;
END $$;


-- ─── B · Demo members ────────────────────────────────────────────────────
-- Guarded: only runs if a members table exists and carries a tenant_id
-- column. Skipping is harmless; you'll see a NOTICE in the seed output.
--
-- The three UUIDs map to the three lifecycle states the demo links on
-- the marketing site exercise:
--
--   550bc413-53db-4f83-98e4-7c5c44d721d0   →  active     (?state=active   / ?result=verified)
--   21e63983-9b15-4cd6-99e4-179e28cd001e   →  inactive   (?state=inactive)
--   fd1be966-ca25-4e64-8a6a-d3402f1fdb58   →  suspended  (?state=suspended / ?result=invalid)

DO $$
DECLARE
  v_tenant_id     uuid;
  v_has_members   boolean;
  v_has_tenant_id boolean;
  v_rows_affected integer;
BEGIN
  SELECT id INTO v_tenant_id FROM public.tenants WHERE slug = 'demo';
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION '[seed] demo tenant insert did not land — aborting member seed';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'members'
  ) INTO v_has_members;

  IF NOT v_has_members THEN
    RAISE NOTICE '[seed] public.members does not exist yet — skipping member seed. '
                 'Apply 0002_members_add_tenant_id.sql (which creates / evolves the table).';
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'members'
      AND column_name  = 'tenant_id'
  ) INTO v_has_tenant_id;

  IF NOT v_has_tenant_id THEN
    RAISE NOTICE '[seed] public.members.tenant_id does not exist yet — skipping member seed. '
                 'Apply 0002_members_add_tenant_id.sql first.';
    RETURN;
  END IF;

  -- Upsert the three carry-over members. We INSERT only the columns we
  -- can be certain exist (id, tenant_id, name, status). If the local
  -- schema has additional NOT NULL columns without defaults, this block
  -- will fail loudly — the right fix is to give those columns defaults
  -- in migration 0002, not to special-case them here.
  INSERT INTO public.members (id, tenant_id, name, status)
  VALUES
    ('550bc413-53db-4f83-98e4-7c5c44d721d0'::uuid, v_tenant_id, 'Demo Member · Active',    'active'),
    ('21e63983-9b15-4cd6-99e4-179e28cd001e'::uuid, v_tenant_id, 'Demo Member · Inactive',  'inactive'),
    ('fd1be966-ca25-4e64-8a6a-d3402f1fdb58'::uuid, v_tenant_id, 'Demo Member · Suspended', 'suspended')
  ON CONFLICT (id) DO UPDATE
    SET tenant_id = EXCLUDED.tenant_id,
        name      = EXCLUDED.name,
        status    = EXCLUDED.status;

  GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
  RAISE NOTICE '[seed] demo members upserted: % rows (tenant_id=%)', v_rows_affected, v_tenant_id;
END $$;


-- ─── C · Smoke check ─────────────────────────────────────────────────────
-- After seeding, the routing pipeline should resolve:
--
--   demo.theunionhub.com           →  card.html  · status=active
--   demo.theunionhub.com/verify    →  verify.html
--
-- Quick verifications (run in psql or the Supabase SQL editor):
--
--   SELECT slug, display_name, status FROM public.tenants WHERE slug='demo';
--   SELECT id, name, status, tenant_id FROM public.members
--     WHERE tenant_id = (SELECT id FROM public.tenants WHERE slug='demo');
--
-- And on the wire (after deploy):
--
--   curl -sI https://demo.theunionhub.com/card | grep -i '^x-tenant-'
--     → x-tenant-id:     <uuid>
--     → x-tenant-slug:   demo
--     → x-tenant-name:   The Union Hub Demo Local
--     → x-tenant-accent: #0F6E56
--     → x-tenant-status: active

COMMIT;
