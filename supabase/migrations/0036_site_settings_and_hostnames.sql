-- =============================================================================
-- 0036_site_settings_and_hostnames.sql · Tier-1 hosted websites — config + hosts
-- =============================================================================
-- First migration of the Tier-1 public-website product. Adds:
--   · site_settings     — one config row per tenant (template, accent, identity,
--                         footer/contact, per-section toggles, published flag).
--   · tenant_hostnames  — hostname → tenant lookup (canonical subdomain AND
--                         custom domains in one table) so public sites resolve
--                         by host uniformly, reusing the same tenant boundary.
--   · site_is_published(tenant) — helper the content tables' public-read
--                         policies gate on (0037).
--   · resolve_site_tenant(hostname) — SECURITY DEFINER lookup the edge renderer
--                         calls to map an incoming host to a tenant.
--
-- Conventions inherited: tenant_id uuid NOT NULL → tenants(id); ENABLE + FORCE
-- RLS; get_request_tenant_id() (0002); is_request_tenant_admin() (0008);
-- set_updated_at() (0001). Public sites are UNAUTHENTICATED — reads are anon,
-- scoped to PUBLISHED sites only; all writes require tenant admin.
--
-- Numbering: 0031 reserved; 0032–0033 identity harvest; 0034–0035 security
-- fixes; 0036+ Tier-1 websites.
-- Idempotent. After applying: NOTIFY pgrst, 'reload schema';
-- =============================================================================

BEGIN;

-- ─── 1 · site_settings ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.site_settings (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Exactly one settings row per tenant.
  tenant_id     uuid        NOT NULL UNIQUE REFERENCES public.tenants(id) ON DELETE RESTRICT,

  -- Which design template renders this site. The approved family (B first).
  template      text        NOT NULL DEFAULT 'editorial'
                              CHECK (template IN ('editorial', 'civic', 'modern')),
  -- Per-tenant accent color token; validated for AA contrast app-side.
  accent_hex    text        NOT NULL DEFAULT '#2F5D7C',
  -- Extra theme tokens (reserved; keeps template theming extensible).
  theme         jsonb       NOT NULL DEFAULT '{}'::jsonb,

  -- Publish gate. A tenant with published = false returns NOTHING publicly.
  published     boolean     NOT NULL DEFAULT false,

  -- Per-section visibility. Identity + footer always render; the rest toggle.
  show_alert     boolean    NOT NULL DEFAULT true,
  show_updates   boolean    NOT NULL DEFAULT true,
  show_about     boolean    NOT NULL DEFAULT true,
  show_executive boolean    NOT NULL DEFAULT true,
  show_stewards  boolean    NOT NULL DEFAULT true,
  show_meetings  boolean    NOT NULL DEFAULT true,
  show_documents boolean    NOT NULL DEFAULT true,

  -- Identity (section 2). local_number / logo may also live on tenants; these
  -- are the website-facing values (a local can present a different public name).
  site_name         text,                 -- full name shown on the site
  tagline           text,
  municipality      text,
  charter_year      int,
  parent_union_name text,                 -- free text; MUST be fictional in demos
  logo_url          text,                 -- Supabase Storage path; nullable
  member_count      int,
  show_member_count boolean NOT NULL DEFAULT true,

  -- About (section 4): narrative body + a flexible facts panel. about_facts is
  -- an array of { "label": "...", "value": "..." } so locals vary what they show
  -- (members / chartered / agreement term / stewards / anything). Empty → the
  -- renderer derives sensible defaults from the fields above.
  about_body        text,
  about_facts       jsonb NOT NULL DEFAULT '[]'::jsonb,

  -- Stewards section standing blurb (editable; sensible default).
  stewards_rights_blurb text NOT NULL DEFAULT
    'You have the right to have a steward present in any meeting with management that could lead to discipline. If you are called into such a meeting, you may ask to pause and contact your steward before it continues.',

  -- Footer / contact (section 9).
  office_address text,
  contact_email  text,
  contact_phone  text,
  affiliations   text,                    -- free-text lines (one per line)

  -- SEO
  meta_description text,

  created_at    timestamptz NOT NULL DEFAULT NOW(),
  updated_at    timestamptz NOT NULL DEFAULT NOW(),

  CONSTRAINT site_settings_accent_hex_shape
    CHECK (accent_hex ~* '^#[0-9a-f]{6}$'),
  CONSTRAINT site_settings_charter_year_sane
    CHECK (charter_year IS NULL OR (charter_year BETWEEN 1800 AND 2100)),
  CONSTRAINT site_settings_member_count_nonneg
    CHECK (member_count IS NULL OR member_count >= 0)
);

DROP TRIGGER IF EXISTS site_settings_set_updated_at ON public.site_settings;
CREATE TRIGGER site_settings_set_updated_at
  BEFORE UPDATE ON public.site_settings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- ─── 2 · tenant_hostnames ───────────────────────────────────────────────────
-- Every host that resolves to a tenant: the canonical {slug}.theunionhub.ca
-- subdomain (is_primary = true, auto-verified) plus any custom domains. A
-- hostname maps to exactly one tenant (global UNIQUE). CASCADE: a hostname is
-- meaningless once its tenant is gone.
CREATE TABLE IF NOT EXISTS public.tenant_hostnames (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  hostname    text        NOT NULL,
  is_primary  boolean     NOT NULL DEFAULT false,
  -- Custom domains start unverified until DNS/ownership is confirmed (phase 3).
  -- The canonical subdomain is inserted verified = true.
  verified    boolean     NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT NOW(),

  CONSTRAINT tenant_hostnames_hostname_shape
    CHECK (hostname = lower(hostname) AND hostname !~ '\s' AND position('/' in hostname) = 0)
);

-- One tenant per hostname, globally.
CREATE UNIQUE INDEX IF NOT EXISTS uq_tenant_hostnames_hostname
  ON public.tenant_hostnames (hostname);
-- At most one primary host per tenant.
CREATE UNIQUE INDEX IF NOT EXISTS uq_tenant_hostnames_one_primary
  ON public.tenant_hostnames (tenant_id) WHERE is_primary;
CREATE INDEX IF NOT EXISTS idx_tenant_hostnames_tenant
  ON public.tenant_hostnames (tenant_id);


-- ─── 3 · Helper: is this tenant's site published? ───────────────────────────
-- STABLE, used by every content table's public-read policy (0037). SECURITY
-- DEFINER so the anon read path can consult site_settings without a broad
-- anon SELECT policy on that table.
CREATE OR REPLACE FUNCTION public.site_is_published(p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.site_settings s
     WHERE s.tenant_id = p_tenant_id
       AND s.published
  );
$$;
REVOKE EXECUTE ON FUNCTION public.site_is_published(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.site_is_published(uuid) TO anon, authenticated;


-- ─── 4 · Resolver: hostname → tenant (for the edge renderer) ────────────────
-- The public site edge function calls this with the incoming Host header. It
-- returns the owning tenant + whether the site is published, so the edge can
-- render, 404 (unknown/unpublished), or handle an unverified custom domain.
-- SECURITY DEFINER: tenant_hostnames has no broad anon policy.
CREATE OR REPLACE FUNCTION public.resolve_site_tenant(p_hostname text)
RETURNS TABLE (
  tenant_id  uuid,
  slug       text,
  published  boolean,
  template   text,
  verified   boolean,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT t.id, t.slug,
         COALESCE(ss.published, false),
         COALESCE(ss.template, 'editorial'),
         h.verified,
         ss.updated_at
    FROM public.tenant_hostnames h
    JOIN public.tenants t        ON t.id = h.tenant_id
    LEFT JOIN public.site_settings ss ON ss.tenant_id = h.tenant_id
   WHERE h.hostname = lower(p_hostname)
   LIMIT 1;
$$;
REVOKE EXECUTE ON FUNCTION public.resolve_site_tenant(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.resolve_site_tenant(text) TO anon, authenticated;


-- ─── 5 · RLS ────────────────────────────────────────────────────────────────
ALTER TABLE public.site_settings    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.site_settings    FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.tenant_hostnames ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_hostnames FORCE  ROW LEVEL SECURITY;

-- site_settings · public read of PUBLISHED sites only (anon renderer + admin).
DROP POLICY IF EXISTS site_settings_public_read ON public.site_settings;
CREATE POLICY site_settings_public_read
  ON public.site_settings FOR SELECT TO anon, authenticated
  USING (published AND tenant_id = public.get_request_tenant_id());

-- site_settings · admins of the tenant read their own row even when unpublished
-- (so the admin editor can load a draft site).
DROP POLICY IF EXISTS site_settings_admin_read ON public.site_settings;
CREATE POLICY site_settings_admin_read
  ON public.site_settings FOR SELECT TO authenticated
  USING (public.is_request_tenant_admin() AND tenant_id = public.get_request_tenant_id());

DROP POLICY IF EXISTS site_settings_admin_write ON public.site_settings;
CREATE POLICY site_settings_admin_write
  ON public.site_settings FOR ALL TO authenticated
  USING      (public.is_request_tenant_admin() AND tenant_id = public.get_request_tenant_id())
  WITH CHECK (public.is_request_tenant_admin() AND tenant_id = public.get_request_tenant_id());

-- tenant_hostnames · admins manage their own; no anon direct read (resolution
-- goes through resolve_site_tenant()).
DROP POLICY IF EXISTS tenant_hostnames_admin_read ON public.tenant_hostnames;
CREATE POLICY tenant_hostnames_admin_read
  ON public.tenant_hostnames FOR SELECT TO authenticated
  USING (public.is_request_tenant_admin() AND tenant_id = public.get_request_tenant_id());

DROP POLICY IF EXISTS tenant_hostnames_admin_write ON public.tenant_hostnames;
CREATE POLICY tenant_hostnames_admin_write
  ON public.tenant_hostnames FOR ALL TO authenticated
  USING      (public.is_request_tenant_admin() AND tenant_id = public.get_request_tenant_id())
  WITH CHECK (public.is_request_tenant_admin() AND tenant_id = public.get_request_tenant_id());

COMMENT ON TABLE public.site_settings IS
  'Tier-1 website config: one row per tenant. template + accent + identity + '
  'footer + per-section toggles + published gate. Public read requires published=true.';
COMMENT ON TABLE public.tenant_hostnames IS
  'Hostname → tenant map for public-site resolution (canonical subdomain + custom '
  'domains). Resolved via resolve_site_tenant(); no broad anon read.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--   -- Unpublished site returns nothing to anon even with the right header:
--   --   set published=false → site_settings_public_read yields 0 rows.
--   -- Resolver maps a host to its tenant:
--   SELECT * FROM public.resolve_site_tenant('local412.theunionhub.ca');
-- ════════════════════════════════════════════════════════════════════════════
