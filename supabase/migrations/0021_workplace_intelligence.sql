-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0021 — workplace_intelligence() RPC
-- ════════════════════════════════════════════════════════════════════════
-- Aggregates member_interactions (0020) into the leadership "Workplace
-- Intelligence" dashboard: total volume, friction by topic, and a worksite
-- heatmap (joined to stewards), over a trailing window (default 30 days).
--
-- Why an RPC (not a client-side SELECT + group-by):
--   · Role-based access is enforced HERE: the function RAISES not_tenant_admin
--     for non-admins, so only is_request_tenant_admin() callers get data. (A
--     plain SELECT on member_interactions would let a steward read their OWN
--     rows under RLS and quietly render a partial dashboard — wrong for a
--     tenant-wide leadership view.)
--   · Aggregation runs in the database; the browser fetches a small JSON
--     summary instead of every interaction row.
--
-- Tenant scope comes from get_request_tenant_id() (x-tenant-id), never an
-- argument. SECURITY DEFINER so it can aggregate under a controlled search_path.
--
-- Prerequisites: 0002 (get_request_tenant_id), 0008 (is_request_tenant_admin),
--                0013 (stewards), 0020 (member_interactions).
-- Idempotency: CREATE OR REPLACE. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.workplace_intelligence(p_days int DEFAULT 30)
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id uuid;
  v_since     timestamptz;
  v_result    json;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context';
  END IF;

  -- Role gate: tenant admins only.
  IF NOT public.is_request_tenant_admin() THEN
    RAISE EXCEPTION 'not_tenant_admin';
  END IF;

  p_days  := GREATEST(1, LEAST(COALESCE(p_days, 30), 365));
  v_since := NOW() - make_interval(days => p_days);

  SELECT json_build_object(
    'days',  p_days,
    'since', v_since,
    'total', (
      SELECT count(*) FROM public.member_interactions mi
       WHERE mi.tenant_id = v_tenant_id AND mi.created_at >= v_since
    ),
    'confirmed', (
      SELECT count(*) FROM public.member_interactions mi
       WHERE mi.tenant_id = v_tenant_id AND mi.created_at >= v_since AND mi.confirmed
    ),
    -- Friction by topic (desc). NULL topic → 'Unspecified'.
    'by_topic', COALESCE((
      SELECT json_agg(t) FROM (
        SELECT COALESCE(mi.topic, 'Unspecified') AS topic, count(*) AS count
          FROM public.member_interactions mi
         WHERE mi.tenant_id = v_tenant_id AND mi.created_at >= v_since
         GROUP BY 1
         ORDER BY count(*) DESC, 1
      ) t
    ), '[]'::json),
    -- Worksite heatmap (desc), joined through stewards. NULL → 'Unassigned'.
    'by_worksite', COALESCE((
      SELECT json_agg(w) FROM (
        SELECT COALESCE(s.worksite, 'Unassigned') AS worksite, count(*) AS count
          FROM public.member_interactions mi
          JOIN public.stewards s ON s.id = mi.steward_id
         WHERE mi.tenant_id = v_tenant_id AND mi.created_at >= v_since
         GROUP BY 1
         ORDER BY count(*) DESC, 1
      ) w
    ), '[]'::json)
  ) INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.workplace_intelligence(int) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.workplace_intelligence(int) TO authenticated;

COMMENT ON FUNCTION public.workplace_intelligence(int) IS
  'Admin-only aggregation of member_interactions for the Workplace Intelligence '
  'dashboard: { days, since, total, confirmed, by_topic[], by_worksite[] } over '
  'the trailing p_days. Tenant-scoped via get_request_tenant_id(); RAISES '
  'not_tenant_admin for non-admins. SECURITY DEFINER.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Ad-hoc equivalent for the SQL Editor (runs as postgres → filter tenant by
-- slug explicitly). The "friction matrix" with rollups:
--
--   SELECT
--     COALESCE(s.worksite, 'Unassigned') AS worksite,
--     COALESCE(mi.topic,   'Unspecified') AS topic,
--     count(*)                            AS interactions
--   FROM public.member_interactions mi
--   JOIN public.stewards s ON s.id = mi.steward_id
--   WHERE mi.tenant_id = (SELECT id FROM public.tenants WHERE slug = 'local183')
--     AND mi.created_at >= now() - interval '30 days'
--   GROUP BY GROUPING SETS ((s.worksite, mi.topic), (s.worksite), (mi.topic), ())
--   ORDER BY worksite NULLS LAST, interactions DESC;
--
-- Verify the gate: SELECT public.workplace_intelligence(30);
--   → as admin: the JSON summary; as non-admin: ERROR not_tenant_admin.
-- ════════════════════════════════════════════════════════════════════════
