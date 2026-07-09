-- =============================================================================
-- 0037_site_content.sql · Tier-1 websites — the content-section tables
-- =============================================================================
-- The structured content each site is composed from (one table per repeatable
-- section): alerts, posts (updates), officers (executive), stewards (public
-- display — NOT the operational public.stewards table), meetings, documents.
--
-- RLS pattern for all six (mirrors site_settings, 0036):
--   · public read  — anon + authenticated, tenant-scoped, ONLY when the site is
--                    published (site_is_published), plus per-table visibility
--                    (posts must be published_at; documents must be 'public').
--   · admin read   — tenant admin reads own rows even when the site is a draft.
--   · admin write  — tenant admin only, own tenant (FOR ALL).
--
-- Depends on: 0036 (site_is_published), 0002/0008 (tenant helpers), 0001
-- (set_updated_at). Idempotent. After applying: NOTIFY pgrst, 'reload schema';
-- =============================================================================

BEGIN;

-- ─── 1 · site_alerts (section 1) ────────────────────────────────────────────
-- Zero-or-one *shown* per site: the render picks the most recent active,
-- unexpired row. History is retained (multiple rows allowed).
CREATE TABLE IF NOT EXISTS public.site_alerts (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,
  message     text        NOT NULL,
  link_url    text,
  link_label  text,
  active      boolean     NOT NULL DEFAULT true,
  expires_at  timestamptz,                -- null = no expiry
  created_at  timestamptz NOT NULL DEFAULT NOW(),
  updated_at  timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT site_alerts_message_not_blank CHECK (length(trim(message)) > 0)
);
CREATE INDEX IF NOT EXISTS idx_site_alerts_tenant ON public.site_alerts (tenant_id);

-- ─── 2 · site_posts (section 3 · updates/notices) ───────────────────────────
CREATE TABLE IF NOT EXISTS public.site_posts (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,
  title        text        NOT NULL,
  -- Restricted rich text (headings/paragraphs/lists/links/bold). Stored as
  -- sanitized HTML; sanitization is enforced in the admin write path (phase 2).
  body         text        NOT NULL DEFAULT '',
  pinned       boolean     NOT NULL DEFAULT false,
  published_at timestamptz,               -- null = draft; set = visible
  created_at   timestamptz NOT NULL DEFAULT NOW(),
  updated_at   timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT site_posts_title_not_blank CHECK (length(trim(title)) > 0)
);
CREATE INDEX IF NOT EXISTS idx_site_posts_tenant_pub
  ON public.site_posts (tenant_id, published_at DESC);

-- ─── 3 · site_officers (section 5 · executive) ──────────────────────────────
CREATE TABLE IF NOT EXISTS public.site_officers (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,
  role_title   text        NOT NULL,
  display_name text        NOT NULL,      -- may be initial-plus-surname
  descriptor   text,
  email        text,
  sort_order   int         NOT NULL DEFAULT 0,
  created_at   timestamptz NOT NULL DEFAULT NOW(),
  updated_at   timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT site_officers_email_shape
    CHECK (email IS NULL OR email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);
CREATE INDEX IF NOT EXISTS idx_site_officers_tenant ON public.site_officers (tenant_id, sort_order);

-- ─── 4 · site_stewards (section 6 · public stewards display) ────────────────
-- Curated public display rows — deliberately separate from the operational
-- public.stewards table (no PII coupling, no auth linkage). contact_method is
-- free text (an email, a phone, "via the office", …).
CREATE TABLE IF NOT EXISTS public.site_stewards (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,
  shift          text,
  area           text,
  steward_name   text        NOT NULL,
  contact_method text,
  sort_order     int         NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL DEFAULT NOW(),
  updated_at     timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT site_stewards_name_not_blank CHECK (length(trim(steward_name)) > 0)
);
CREATE INDEX IF NOT EXISTS idx_site_stewards_tenant ON public.site_stewards (tenant_id, sort_order);

-- ─── 5 · site_meetings (section 7) ──────────────────────────────────────────
-- meeting_type = 'featured' → the next-meeting card (starts_at/location/notes).
-- meeting_type = 'schedule' → a recurring-schedule line (title = label,
-- schedule_note = value, e.g. "General membership" / "Third Tuesday, monthly").
CREATE TABLE IF NOT EXISTS public.site_meetings (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,
  meeting_type  text        NOT NULL DEFAULT 'schedule'
                              CHECK (meeting_type IN ('featured', 'schedule')),
  title         text        NOT NULL,
  starts_at     timestamptz,              -- featured only
  location      text,                     -- featured only
  notes         text,                     -- featured only
  schedule_note text,                     -- schedule lines: the "value" text
  sort_order    int         NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT NOW(),
  updated_at    timestamptz NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_site_meetings_tenant ON public.site_meetings (tenant_id, meeting_type, sort_order);

-- ─── 6 · site_documents (section 8) ─────────────────────────────────────────
-- visibility ships now so Tier 2 gates 'members' docs behind login with NO
-- migration — only the public-read policy changes. Tier 1 shows 'public' only.
CREATE TABLE IF NOT EXISTS public.site_documents (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,
  category     text,
  title        text        NOT NULL,
  meta         text,                       -- meta line, e.g. "PDF · Agreement · 1.8 MB"
  storage_path text,                       -- Supabase Storage object path
  file_size    bigint,
  visibility   text        NOT NULL DEFAULT 'public'
                             CHECK (visibility IN ('public', 'members')),
  sort_order   int         NOT NULL DEFAULT 0,
  created_at   timestamptz NOT NULL DEFAULT NOW(),
  updated_at   timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT site_documents_title_not_blank CHECK (length(trim(title)) > 0)
);
CREATE INDEX IF NOT EXISTS idx_site_documents_tenant ON public.site_documents (tenant_id, sort_order);


-- ─── 7 · updated_at triggers ────────────────────────────────────────────────
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['site_alerts','site_posts','site_officers','site_stewards','site_meetings','site_documents']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_set_updated_at', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()', t || '_set_updated_at', t);
  END LOOP;
END $$;


-- ─── 8 · RLS ────────────────────────────────────────────────────────────────
-- Enable + force on all six.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['site_alerts','site_posts','site_officers','site_stewards','site_meetings','site_documents']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE public.%I FORCE  ROW LEVEL SECURITY', t);
    -- Admin read (draft sites) + admin write (FOR ALL), own tenant.
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_admin_read', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                      USING (public.is_request_tenant_admin() AND tenant_id = public.get_request_tenant_id())$p$,
                   t || '_admin_read', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_admin_write', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING      (public.is_request_tenant_admin() AND tenant_id = public.get_request_tenant_id())
                      WITH CHECK (public.is_request_tenant_admin() AND tenant_id = public.get_request_tenant_id())$p$,
                   t || '_admin_write', t);
  END LOOP;
END $$;

-- Public reads (anon + authenticated), PUBLISHED sites only, per-table extra gates.
DROP POLICY IF EXISTS site_alerts_public_read ON public.site_alerts;
CREATE POLICY site_alerts_public_read ON public.site_alerts FOR SELECT TO anon, authenticated
  USING (tenant_id = public.get_request_tenant_id() AND public.site_is_published(tenant_id));

DROP POLICY IF EXISTS site_posts_public_read ON public.site_posts;
CREATE POLICY site_posts_public_read ON public.site_posts FOR SELECT TO anon, authenticated
  USING (tenant_id = public.get_request_tenant_id() AND public.site_is_published(tenant_id)
         AND published_at IS NOT NULL AND published_at <= now());

DROP POLICY IF EXISTS site_officers_public_read ON public.site_officers;
CREATE POLICY site_officers_public_read ON public.site_officers FOR SELECT TO anon, authenticated
  USING (tenant_id = public.get_request_tenant_id() AND public.site_is_published(tenant_id));

DROP POLICY IF EXISTS site_stewards_public_read ON public.site_stewards;
CREATE POLICY site_stewards_public_read ON public.site_stewards FOR SELECT TO anon, authenticated
  USING (tenant_id = public.get_request_tenant_id() AND public.site_is_published(tenant_id));

DROP POLICY IF EXISTS site_meetings_public_read ON public.site_meetings;
CREATE POLICY site_meetings_public_read ON public.site_meetings FOR SELECT TO anon, authenticated
  USING (tenant_id = public.get_request_tenant_id() AND public.site_is_published(tenant_id));

-- Tier 1: only 'public' documents are ever readable anonymously. Tier 2 will
-- relax this to allow 'members' docs for authenticated members — policy change
-- only, no migration to the table.
DROP POLICY IF EXISTS site_documents_public_read ON public.site_documents;
CREATE POLICY site_documents_public_read ON public.site_documents FOR SELECT TO anon, authenticated
  USING (tenant_id = public.get_request_tenant_id() AND public.site_is_published(tenant_id)
         AND visibility = 'public');

COMMENT ON TABLE public.site_stewards IS
  'Public, curated stewards-section display rows for Tier-1 websites. Distinct '
  'from public.stewards (operational, PII, auth-linked) by design — no coupling.';
COMMENT ON COLUMN public.site_documents.visibility IS
  'public | members. Tier 1 exposes public only; the members gate is a Tier-2 '
  'policy change, no schema migration.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Post-migration verification (all gated on published=true):
--   -- With published=false: anon SELECT on every site_* table → 0 rows.
--   -- With published=true : anon sees officers/stewards/meetings/alerts, posts
--   --   with published_at<=now, and documents with visibility='public' only.
--   -- Draft posts (published_at IS NULL) and 'members' documents never anon-read.
-- ════════════════════════════════════════════════════════════════════════════
