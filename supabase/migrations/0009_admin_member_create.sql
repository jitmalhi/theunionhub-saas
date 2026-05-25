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

BEGIN;


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

COMMIT;

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
