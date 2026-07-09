-- =============================================================================
-- 0039_export_site.sql · Tier-1 websites — content export (your content is yours)
-- =============================================================================
-- export_site() returns a tenant's ENTIRE site as one jsonb bundle — every
-- setting, every content row (INCLUDING drafts and 'members' documents, unlike
-- get_public_site), all hostnames, plus a `files` manifest of storage objects to
-- fetch. Backs the contractual content-ownership promise. Admin-only.
--
-- SECURITY DEFINER (reads past RLS to gather drafts) but HARD-gated: it raises
-- 42501 unless the caller is a verified admin of the current tenant
-- (is_request_tenant_admin() over auth.uid() + the x-tenant-id header). Called
-- via api/site-export.js, which forwards the admin's JWT + x-tenant-id.
--
-- Depends on: 0002/0008 (tenant helpers), 0036–0037 (site tables). Idempotent.
-- After applying: NOTIFY pgrst, 'reload schema';
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.export_site()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tid uuid;
BEGIN
  v_tid := public.get_request_tenant_id();
  IF v_tid IS NULL OR NOT public.is_request_tenant_admin() THEN
    RAISE EXCEPTION 'export_site: tenant admin required'
      USING errcode = '42501';  -- insufficient_privilege → 403 at PostgREST
  END IF;

  RETURN jsonb_build_object(
    'schema',      'union-hub.site-export/1',
    'exported_at', now(),
    'tenant', (
      SELECT jsonb_build_object('id', t.id, 'slug', t.slug,
               'display_name', t.display_name, 'local_number', t.local_number,
               'accent_hex', t.accent_hex)
        FROM public.tenants t WHERE t.id = v_tid
    ),
    'hostnames', COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.is_primary DESC)
                   FROM public.tenant_hostnames h WHERE h.tenant_id = v_tid), '[]'::jsonb),
    'settings',  (SELECT to_jsonb(s) FROM public.site_settings s WHERE s.tenant_id = v_tid),
    'alerts',    COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.created_at DESC)
                   FROM public.site_alerts a WHERE a.tenant_id = v_tid), '[]'::jsonb),
    'posts',     COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.published_at DESC NULLS LAST, p.created_at DESC)
                   FROM public.site_posts p WHERE p.tenant_id = v_tid), '[]'::jsonb),
    'officers',  COALESCE((SELECT jsonb_agg(to_jsonb(o) ORDER BY o.sort_order)
                   FROM public.site_officers o WHERE o.tenant_id = v_tid), '[]'::jsonb),
    'stewards',  COALESCE((SELECT jsonb_agg(to_jsonb(w) ORDER BY w.sort_order)
                   FROM public.site_stewards w WHERE w.tenant_id = v_tid), '[]'::jsonb),
    'meetings',  COALESCE((SELECT jsonb_agg(to_jsonb(m) ORDER BY m.meeting_type, m.sort_order)
                   FROM public.site_meetings m WHERE m.tenant_id = v_tid), '[]'::jsonb),
    'documents', COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.sort_order)
                   FROM public.site_documents d WHERE d.tenant_id = v_tid), '[]'::jsonb),
    -- files manifest: the binary objects a full backup must also fetch.
    'files', COALESCE((
      SELECT jsonb_agg(x) FROM (
        SELECT jsonb_build_object('kind','document','title',d.title,
                 'storage_path',d.storage_path,'visibility',d.visibility) AS x
          FROM public.site_documents d
         WHERE d.tenant_id = v_tid AND d.storage_path IS NOT NULL AND d.storage_path <> '#'
        UNION ALL
        SELECT jsonb_build_object('kind','logo','storage_path',s.logo_url)
          FROM public.site_settings s
         WHERE s.tenant_id = v_tid AND s.logo_url IS NOT NULL
      ) q), '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.export_site() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.export_site() TO authenticated;

COMMENT ON FUNCTION public.export_site() IS
  'Full Tier-1 site export (settings + all content incl drafts + hostnames + '
  'files manifest) as one jsonb bundle. SECURITY DEFINER, admin-gated. Backs the '
  'content-ownership promise; called by api/site-export.js.';

COMMIT;
