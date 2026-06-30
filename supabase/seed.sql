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
-- The three demo UUIDs originated in the prototype's js/live.js (now
-- lib/live.js) and are still referenced from card.html?id=… and
-- verify.html?id=… for the live demo links on the marketing site.
-- Changing them here means updating those references too — keep this
-- file in sync with the inline DEMO_IDS in card.html / verify.html.
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
  -- can be certain exist (id, tenant_id, full_name, status). If the local
  -- schema has additional NOT NULL columns without defaults, this block
  -- will fail loudly — the right fix is to give those columns defaults
  -- in migration 0002, not to special-case them here.
  INSERT INTO public.members (id, tenant_id, full_name, status)
  VALUES
    ('550bc413-53db-4f83-98e4-7c5c44d721d0'::uuid, v_tenant_id, 'Demo Member · Active',    'active'),
    ('21e63983-9b15-4cd6-99e4-179e28cd001e'::uuid, v_tenant_id, 'Demo Member · Inactive',  'inactive'),
    ('fd1be966-ca25-4e64-8a6a-d3402f1fdb58'::uuid, v_tenant_id, 'Demo Member · Suspended', 'suspended')
  ON CONFLICT (id) DO UPDATE
    SET tenant_id = EXCLUDED.tenant_id,
        full_name = EXCLUDED.full_name,
        status    = EXCLUDED.status;

  GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
  RAISE NOTICE '[seed] demo members upserted: % rows (tenant_id=%)', v_rows_affected, v_tenant_id;
END $$;


-- ─── C · Demo steward ────────────────────────────────────────────────────
-- Guarded: only runs once migration 0013 has created public.stewards.
-- Skipping is harmless (NOTICE in seed output). The id is pinned to a fixed
-- uuid so the demo scan URL is stable and copy-pasteable:
--
--   demo.theunionhub.com/access/a57e0a00-0000-4000-8000-000000000001
--   demo.lvh.me:3000/access/a57e0a00-0000-4000-8000-000000000001   (local dev)
--
-- user_id is left NULL on purpose — this mirrors the launch reality where an
-- admin pre-creates a steward and prints the permanent QR before that person
-- has ever signed in (self-edit activates later, once they log in). member_id
-- is linked best-effort to the active demo member if Section B seeded it.

DO $$
DECLARE
  v_tenant_id  uuid;
  v_has_stew   boolean;
  v_member_id  uuid;
  v_steward_id uuid := 'a57e0a00-0000-4000-8000-000000000001'::uuid;
BEGIN
  SELECT id INTO v_tenant_id FROM public.tenants WHERE slug = 'demo';
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION '[seed] demo tenant missing — aborting steward seed';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'stewards'
  ) INTO v_has_stew;

  IF NOT v_has_stew THEN
    RAISE NOTICE '[seed] public.stewards does not exist yet — skipping steward seed. '
                 'Apply 0013_stewards.sql first.';
    RETURN;
  END IF;

  -- Best-effort link to the active demo member (NULL if Section B skipped).
  SELECT id INTO v_member_id
    FROM public.members
   WHERE id = '550bc413-53db-4f83-98e4-7c5c44d721d0'::uuid
     AND tenant_id = v_tenant_id;

  INSERT INTO public.stewards (
    id, tenant_id, user_id, member_id,
    full_name, title, role, email, phone, worksite, bio,
    status, appointed_at
  )
  VALUES (
    v_steward_id, v_tenant_id, NULL, v_member_id,
    'Maya Okonkwo',
    'Chief Shop Steward',
    'steward',                                   -- credential tier (0015)
    'maya.okonkwo@demo.theunionhub.com',
    '+1-555-0100',
    'Plant 2 · Day Shift',
    'Day-shift steward at Plant 2. Reach out about scheduling, grievances, or health-and-safety concerns — I am here to help.',
    'active',
    '2019-04-12'
  )
  ON CONFLICT (id) DO UPDATE
    SET tenant_id    = EXCLUDED.tenant_id,
        member_id    = EXCLUDED.member_id,
        full_name    = EXCLUDED.full_name,
        title        = EXCLUDED.title,
        role         = EXCLUDED.role,
        email        = EXCLUDED.email,
        phone        = EXCLUDED.phone,
        worksite     = EXCLUDED.worksite,
        bio          = EXCLUDED.bio,
        status       = EXCLUDED.status,
        appointed_at = EXCLUDED.appointed_at;

  RAISE NOTICE '[seed] demo steward: % (id=%, tenant=%, member=%)',
               'Maya Okonkwo', v_steward_id, v_tenant_id, COALESCE(v_member_id::text, 'none');
END $$;


-- ─── D · Smoke check ─────────────────────────────────────────────────────
-- After seeding, the routing pipeline should resolve:
--
--   demo.theunionhub.com           →  card.html  · status=active
--   demo.theunionhub.com/verify    →  verify.html
--   demo.theunionhub.com/access/a57e0a00-0000-4000-8000-000000000001
--                                  →  access.html · Maya Okonkwo
--
-- Quick verifications (run in psql or the Supabase SQL editor):
--
--   SELECT slug, display_name, status FROM public.tenants WHERE slug='demo';
--   SELECT id, full_name, status, tenant_id FROM public.members
--     WHERE tenant_id = (SELECT id FROM public.tenants WHERE slug='demo');
--   SELECT id, full_name, title, status FROM public.stewards
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
