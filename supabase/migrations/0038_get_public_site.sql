-- =============================================================================
-- 0038_get_public_site.sql · Tier-1 websites — one-call published-site read
-- =============================================================================
-- The edge renderer needs the WHOLE site in one round trip (3G target). This
-- SECURITY DEFINER function returns the published site as a single jsonb blob,
-- or NULL when the tenant has no published site (→ the renderer 404s). It reads
-- past RLS by design but is hard-gated on site_settings.published, and returns
-- only public-safe fields (public documents only; only published posts).
--
-- Depends on: 0036 (site_settings), 0037 (content tables). Idempotent.
-- After applying: NOTIFY pgrst, 'reload schema';
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_public_site(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH s AS (
    SELECT * FROM public.site_settings
     WHERE tenant_id = p_tenant_id AND published
     LIMIT 1
  )
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM s) THEN NULL::jsonb ELSE
    jsonb_build_object(
      'tenant', (
        SELECT jsonb_build_object(
          'id', t.id, 'slug', t.slug,
          'local_number', t.local_number,
          'display_name', t.display_name,
          'logo_url', t.logo_url
        ) FROM public.tenants t WHERE t.id = p_tenant_id
      ),
      'primary_host', (
        SELECT h.hostname FROM public.tenant_hostnames h
         WHERE h.tenant_id = p_tenant_id AND h.is_primary LIMIT 1
      ),
      'settings', (SELECT to_jsonb(s) FROM s),
      'alert', (
        SELECT to_jsonb(a) FROM public.site_alerts a
         WHERE a.tenant_id = p_tenant_id AND a.active
           AND (a.expires_at IS NULL OR a.expires_at > now())
         ORDER BY a.created_at DESC LIMIT 1
      ),
      'posts', COALESCE((
        SELECT jsonb_agg(to_jsonb(p) ORDER BY p.pinned DESC, p.published_at DESC)
          FROM public.site_posts p
         WHERE p.tenant_id = p_tenant_id
           AND p.published_at IS NOT NULL AND p.published_at <= now()
      ), '[]'::jsonb),
      'officers', COALESCE((
        SELECT jsonb_agg(to_jsonb(o) ORDER BY o.sort_order, o.created_at)
          FROM public.site_officers o WHERE o.tenant_id = p_tenant_id
      ), '[]'::jsonb),
      'stewards', COALESCE((
        SELECT jsonb_agg(to_jsonb(w) ORDER BY w.sort_order, w.created_at)
          FROM public.site_stewards w WHERE w.tenant_id = p_tenant_id
      ), '[]'::jsonb),
      'meetings', COALESCE((
        SELECT jsonb_agg(to_jsonb(m) ORDER BY m.meeting_type, m.sort_order, m.starts_at)
          FROM public.site_meetings m WHERE m.tenant_id = p_tenant_id
      ), '[]'::jsonb),
      'documents', COALESCE((
        SELECT jsonb_agg(to_jsonb(d) ORDER BY d.sort_order, d.created_at)
          FROM public.site_documents d
         WHERE d.tenant_id = p_tenant_id AND d.visibility = 'public'
      ), '[]'::jsonb)
    )
  END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_public_site(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_public_site(uuid) TO anon, authenticated;

COMMENT ON FUNCTION public.get_public_site(uuid) IS
  'Whole published Tier-1 site as one jsonb blob for the edge renderer (or NULL '
  'if unpublished). SECURITY DEFINER, hard-gated on site_settings.published; '
  'returns public documents + published posts only.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Verify: SELECT get_public_site((SELECT id FROM tenants WHERE slug='local412'));
--   → NULL when unpublished; a full object (tenant/settings/alert/posts/…) when published.
-- ════════════════════════════════════════════════════════════════════════════
