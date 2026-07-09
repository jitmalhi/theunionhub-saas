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


-- ─── E · Tier-1 website demo · Local 412 ─────────────────────────────────────
-- Canonical website demo tenant (see UX design/MOCKUP-RULES.md). A separate
-- tenant from 'demo': Allied Health & Service Workers, Local 412. Guarded on the
-- site_* tables existing (migrations 0036–0038). Idempotent: content rows are
-- deleted-then-reinserted per run. Dates anchored to mid-July 2026.

BEGIN;

INSERT INTO public.tenants (slug, display_name, local_number, union_type, accent_hex, contact_email, status)
VALUES ('local412', 'Allied Health & Service Workers, Local 412', '412', 'Allied Health & Service Workers', '#2F5D7C', 'info@local412.example', 'active')
ON CONFLICT (slug) DO UPDATE
  SET display_name = EXCLUDED.display_name, local_number = EXCLUDED.local_number,
      union_type = EXCLUDED.union_type, accent_hex = EXCLUDED.accent_hex,
      contact_email = EXCLUDED.contact_email, status = EXCLUDED.status;

DO $$
DECLARE
  v_tid uuid;
  v_has_site boolean;
BEGIN
  SELECT id INTO v_tid FROM public.tenants WHERE slug = 'local412';

  SELECT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema='public' AND table_name='site_settings') INTO v_has_site;
  IF NOT v_has_site THEN
    RAISE NOTICE '[seed] site_settings missing — skipping Local 412 website seed (apply 0036–0038 first).';
    RETURN;
  END IF;

  -- Hostnames: canonical .ca subdomain (verified) + a demo custom domain.
  INSERT INTO public.tenant_hostnames (tenant_id, hostname, is_primary, verified) VALUES
    (v_tid, 'local412.theunionhub.ca', true,  true),
    (v_tid, 'local412.example',        false, false)
  ON CONFLICT (hostname) DO UPDATE
    SET tenant_id = EXCLUDED.tenant_id, is_primary = EXCLUDED.is_primary, verified = EXCLUDED.verified;

  -- Fresh content each run.
  DELETE FROM public.site_alerts    WHERE tenant_id = v_tid;
  DELETE FROM public.site_posts     WHERE tenant_id = v_tid;
  DELETE FROM public.site_officers  WHERE tenant_id = v_tid;
  DELETE FROM public.site_stewards  WHERE tenant_id = v_tid;
  DELETE FROM public.site_meetings  WHERE tenant_id = v_tid;
  DELETE FROM public.site_documents WHERE tenant_id = v_tid;

  INSERT INTO public.site_settings (
    tenant_id, template, accent_hex, published,
    site_name, tagline, municipality, charter_year, parent_union_name,
    member_count, show_member_count, about_body, about_facts,
    office_address, contact_email, contact_phone, affiliations, meta_description
  ) VALUES (
    v_tid, 'editorial', '#2F5D7C', true,
    'Allied Health & Service Workers, Local 412',
    'Representing healthcare workers at Lakeview Regional Health Centre since 1974.',
    'Riverbend', 1974, 'Allied Health & Service Workers',
    340, true,
    E'Local 412 represents roughly 340 healthcare workers — nurses, personal support workers, diagnostic and support staff — at Lakeview Regional Health Centre in Riverbend. We have held our charter since 1974.\n\nOur work is straightforward: enforce the collective agreement, represent members in grievances and discipline, keep workplaces safe, and bargain a fair contract.',
    '[{"label":"Members","value":"~340"},{"label":"Chartered","value":"1974"},{"label":"Agreement term","value":"2023–2026"},{"label":"Stewards","value":"8"},{"label":"Employer","value":"Lakeview Regional"}]'::jsonb,
    E'Union office\n118 Riverbend Main St, Suite 4\nRiverbend',
    'info@local412.example', '(555) 018-0412',
    'Affiliated with Allied Health & Service Workers · Riverbend & District Labour Council',
    'Allied Health & Service Workers, Local 412 — representing healthcare workers at Lakeview Regional Health Centre in Riverbend since 1974.'
  )
  ON CONFLICT (tenant_id) DO UPDATE SET
    template=EXCLUDED.template, accent_hex=EXCLUDED.accent_hex, published=EXCLUDED.published,
    site_name=EXCLUDED.site_name, tagline=EXCLUDED.tagline, municipality=EXCLUDED.municipality,
    charter_year=EXCLUDED.charter_year, parent_union_name=EXCLUDED.parent_union_name,
    member_count=EXCLUDED.member_count, show_member_count=EXCLUDED.show_member_count,
    about_body=EXCLUDED.about_body, about_facts=EXCLUDED.about_facts,
    office_address=EXCLUDED.office_address, contact_email=EXCLUDED.contact_email,
    contact_phone=EXCLUDED.contact_phone, affiliations=EXCLUDED.affiliations,
    meta_description=EXCLUDED.meta_description;

  INSERT INTO public.site_alerts (tenant_id, message, link_url, link_label, active, expires_at) VALUES
    (v_tid, 'Bargaining update meeting — Thursday, July 16, 2026, 6:30 PM, Riverbend Community Hall.', '#meetings', 'Details', true, '2026-07-17T00:00:00Z');

  INSERT INTO public.site_posts (tenant_id, title, body, pinned, published_at) VALUES
    (v_tid, 'Tentative dates set for renewal bargaining',
      '<p>The bargaining committee has confirmed dates with the employer for renewal of the 2023–2026 agreement. A membership update meeting is scheduled for July 16 — all members are encouraged to attend.</p>', true, '2026-07-02T12:00:00Z'),
    (v_tid, 'Q2 membership meeting recap',
      '<p>Minutes and the treasurer''s report from the June general meeting are now posted under Documents. Thank you to everyone who attended.</p>', false, '2026-06-18T12:00:00Z'),
    (v_tid, 'New health & safety representatives posted',
      '<p>Two new worker representatives have joined the joint health and safety committee. Contact your steward to raise a concern for the next meeting.</p>', false, '2026-06-05T12:00:00Z');

  INSERT INTO public.site_officers (tenant_id, role_title, display_name, descriptor, sort_order) VALUES
    (v_tid, 'President', 'M. Delgado', 'Chief spokesperson & bargaining lead', 0),
    (v_tid, 'Vice-President', 'A. Kaur', 'Grievances & membership', 1),
    (v_tid, 'Secretary-Treasurer', 'R. Whitefeather', 'Finances & records', 2),
    (v_tid, 'Recording Secretary', 'T. Okafor', 'Minutes & correspondence', 3);

  INSERT INTO public.site_stewards (tenant_id, shift, area, steward_name, contact_method, sort_order) VALUES
    (v_tid, 'Days', 'Emergency & ICU', 'E. Vance · Chief Steward', 'evance@local412.example', 0),
    (v_tid, 'Days', 'Medical / Surgical', 'S. Brar', 'sbrar@local412.example', 1),
    (v_tid, 'Nights', 'Long-Term Care', 'J. Osei', 'josei@local412.example', 2),
    (v_tid, 'Rotating', 'Diagnostic Imaging', 'P. Lindgren', 'plindgren@local412.example', 3);

  INSERT INTO public.site_meetings (tenant_id, meeting_type, title, starts_at, location, notes, schedule_note, sort_order) VALUES
    (v_tid, 'featured', 'General Membership Meeting', '2026-07-21T19:00:00Z', 'Riverbend Community Hall, 40 Main St', 'All members welcome; bring your membership card', NULL, 0),
    (v_tid, 'schedule', 'General membership', NULL, NULL, NULL, 'Third Tuesday, monthly', 1),
    (v_tid, 'schedule', 'Executive board', NULL, NULL, NULL, 'First Monday, monthly', 2),
    (v_tid, 'schedule', 'Health & safety committee', NULL, NULL, NULL, 'Second Wednesday, monthly', 3);

  INSERT INTO public.site_documents (tenant_id, category, title, meta, storage_path, visibility, sort_order) VALUES
    (v_tid, 'Agreement',  'Collective Agreement 2023–2026',      'PDF · Agreement · 1.8 MB',  '#', 'public', 0),
    (v_tid, 'Governance', 'Local 412 Bylaws',                    'PDF · Governance · 320 KB', '#', 'public', 1),
    (v_tid, 'Forms',      'Grievance Form',                      'PDF · Forms · 180 KB',      '#', 'public', 2),
    (v_tid, 'Committees', 'Health & Safety — Meeting Minutes',   'PDF · Committees · 240 KB', '#', 'public', 3);

  RAISE NOTICE '[seed] Local 412 website seeded (tenant %, published) — local412.theunionhub.ca', v_tid;
END $$;

COMMIT;
