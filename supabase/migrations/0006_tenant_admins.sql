-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0006 — tenant_admins (multi-admin support)
-- ════════════════════════════════════════════════════════════════════════
-- Replaces the v1 single-admin model (where update_tenant_settings only
-- accepted the user whose email matched tenants.contact_email) with a
-- real membership table linking auth.users to tenants.
--
-- Backward compatibility — the bootstrap problem
-- ─────────────────────────────────────────────────────────────────────
-- Two scenarios this migration has to handle gracefully:
--
--   A · A tenant exists, its contact_email has signed in at least once,
--       so an auth.users row exists. Backfill inserts a tenant_admins
--       row for them. They keep working without interruption.
--
--   B · A tenant exists, its contact_email user has never signed in.
--       Backfill skips them (we can't insert a tenant_admins row
--       referencing a nonexistent auth.users.id). After they sign in
--       for the first time, is_tenant_admin's "bootstrap fallback"
--       (no tenant_admins rows exist yet → fall back to contact_email
--       match) recognises them. The first time they call add_tenant_admin
--       to invite a co-admin, the RPC auto-promotes them into the
--       tenant_admins table so they don't lose access when the bootstrap
--       fallback turns off.
--
-- The bootstrap fallback is intentionally narrow: it only applies when
-- the tenant has zero rows in tenant_admins. Once at least one row
-- exists, contact_email is no longer implicitly an admin — they must
-- be explicitly listed. This is correct: if you've added co-admins,
-- you've moved into "real" multi-admin mode and the email field becomes
-- contact metadata only.
--
-- Function ownership
-- ─────────────────────────────────────────────────────────────────────
-- is_tenant_admin, add_tenant_admin, remove_tenant_admin are all
-- SECURITY DEFINER. They read auth.users (which authenticated users
-- can't read directly), write to tenant_admins (which has no
-- INSERT/UPDATE/DELETE policies for non-service roles), and read
-- public.tenants (where the read is just a sanity check). Lockdown:
-- REVOKE EXECUTE FROM PUBLIC, GRANT EXECUTE TO authenticated.
--
-- Prerequisites: 0001 (tenants), 0002 (get_request_tenant_id),
--                0004 (audit_log), 0005 (update_tenant_settings).
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ─── 1 · Table ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.tenant_admins (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES public.tenants(id)  ON DELETE RESTRICT,
  user_id     uuid        NOT NULL REFERENCES auth.users(id)      ON DELETE RESTRICT,
  role        text        NOT NULL DEFAULT 'admin',
  created_at  timestamptz NOT NULL DEFAULT NOW(),
  created_by  uuid        REFERENCES auth.users(id),

  -- The role enum is intentionally tiny for v1. Adding 'viewer' or
  -- 'steward' later means extending the CHECK and updating callers; the
  -- column is here to make that growth path explicit, not because v1
  -- distinguishes roles.
  CONSTRAINT tenant_admins_role_known CHECK (role IN ('admin')),
  CONSTRAINT tenant_admins_unique     UNIQUE (tenant_id, user_id)
);

CREATE INDEX IF NOT EXISTS tenant_admins_user_idx   ON public.tenant_admins (user_id);
CREATE INDEX IF NOT EXISTS tenant_admins_tenant_idx ON public.tenant_admins (tenant_id);


-- ─── 2 · RLS ────────────────────────────────────────────────────────────
ALTER TABLE public.tenant_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_admins FORCE  ROW LEVEL SECURITY;

-- Authenticated users can SELECT admins of the tenant in their x-tenant-id
-- context (so the admin team page can list "who else has access"). They
-- cannot mutate directly — only the add_tenant_admin / remove_tenant_admin
-- RPCs can, both of which check is_tenant_admin first.
DROP POLICY IF EXISTS tenant_admins_read ON public.tenant_admins;
CREATE POLICY tenant_admins_read
  ON public.tenant_admins
  FOR SELECT
  TO authenticated
  USING (tenant_id = public.get_request_tenant_id());


-- ─── 3 · is_tenant_admin(p_tenant_id, p_user_id) → boolean ─────────────
CREATE OR REPLACE FUNCTION public.is_tenant_admin(p_tenant_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_user_email    text;
  v_contact_email text;
  v_has_any       boolean;
BEGIN
  IF p_tenant_id IS NULL OR p_user_id IS NULL THEN
    RETURN false;
  END IF;

  -- Explicit membership wins. Fast path; most authorised calls land here.
  IF EXISTS (
    SELECT 1 FROM public.tenant_admins
     WHERE tenant_id = p_tenant_id AND user_id = p_user_id
  ) THEN
    RETURN true;
  END IF;

  -- Bootstrap fallback: while the tenant has zero rows in tenant_admins,
  -- the contact_email user is implicitly an admin so newly-provisioned
  -- tenants can be operated by the founding email. The moment any
  -- tenant_admins row exists for the tenant, this fallback turns off —
  -- the contact_email user must then be explicitly listed in
  -- tenant_admins. add_tenant_admin handles this transition by
  -- auto-promoting the caller before adding the new admin.
  SELECT EXISTS (
    SELECT 1 FROM public.tenant_admins WHERE tenant_id = p_tenant_id
  ) INTO v_has_any;
  IF v_has_any THEN
    RETURN false;
  END IF;

  SELECT email         INTO v_user_email    FROM auth.users        WHERE id = p_user_id;
  SELECT contact_email INTO v_contact_email FROM public.tenants    WHERE id = p_tenant_id;

  RETURN v_user_email IS NOT NULL
     AND v_contact_email IS NOT NULL
     AND lower(v_user_email) = lower(v_contact_email);
END;
$$;

COMMENT ON FUNCTION public.is_tenant_admin(uuid, uuid) IS
  'True if the user is an admin of the tenant. Checks explicit tenant_admins '
  'membership first; falls back to contact_email match only when the tenant '
  'has zero rows in tenant_admins (bootstrap fallback for newly-provisioned '
  'tenants). SECURITY DEFINER so it can read auth.users.';


-- ─── 4 · add_tenant_admin(p_email) → tenant_admins row ─────────────────
CREATE OR REPLACE FUNCTION public.add_tenant_admin(p_email text)
RETURNS public.tenant_admins
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id    uuid;
  v_caller_id    uuid;
  v_target_id    uuid;
  v_target_email text;
  v_result       public.tenant_admins%ROWTYPE;
  v_was_bootstrap boolean;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context';
  END IF;

  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.is_tenant_admin(v_tenant_id, v_caller_id) THEN
    RAISE EXCEPTION 'not_tenant_admin';
  END IF;

  -- Auto-promote the caller into tenant_admins if they currently qualify
  -- only via the bootstrap fallback. Without this, adding the first
  -- co-admin would activate the "explicit only" mode and immediately
  -- lock the caller out.
  v_was_bootstrap := NOT EXISTS (
    SELECT 1 FROM public.tenant_admins
     WHERE tenant_id = v_tenant_id AND user_id = v_caller_id
  );

  IF v_was_bootstrap THEN
    INSERT INTO public.tenant_admins (tenant_id, user_id, role, created_by)
    VALUES (v_tenant_id, v_caller_id, 'admin', v_caller_id)
    ON CONFLICT (tenant_id, user_id) DO NOTHING;

    INSERT INTO public.audit_log (tenant_id, actor, action, target_type, target_id, detail)
    VALUES (
      v_tenant_id,
      'user:' || v_caller_id::text,
      'tenant_admin_self_promoted',
      'user',
      v_caller_id,
      jsonb_build_object('reason', 'bootstrap_to_explicit')
    );
  END IF;

  -- Validate + look up the target email.
  v_target_email := lower(trim(p_email));
  IF v_target_email = ''
     OR v_target_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'invalid_email';
  END IF;

  SELECT id INTO v_target_id FROM auth.users WHERE lower(email) = v_target_email;
  IF v_target_id IS NULL THEN
    RAISE EXCEPTION 'user_not_signed_in_yet'
      USING HINT = 'Have them sign in via /admin/signin once, then try adding them again';
  END IF;

  -- Insert. If the user is already an admin, this is a no-op (ON CONFLICT)
  -- and we return the existing row.
  INSERT INTO public.tenant_admins (tenant_id, user_id, role, created_by)
  VALUES (v_tenant_id, v_target_id, 'admin', v_caller_id)
  ON CONFLICT (tenant_id, user_id) DO UPDATE
    SET role = EXCLUDED.role           -- no-op but lets RETURNING fire
  RETURNING * INTO v_result;

  INSERT INTO public.audit_log (tenant_id, actor, action, target_type, target_id, detail)
  VALUES (
    v_tenant_id,
    'user:' || v_caller_id::text,
    'tenant_admin_added',
    'user',
    v_target_id,
    jsonb_build_object('email', v_target_email)
  );

  RETURN v_result;
END;
$$;


-- ─── 5 · remove_tenant_admin(p_user_id) → void ─────────────────────────
CREATE OR REPLACE FUNCTION public.remove_tenant_admin(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id uuid;
  v_caller_id uuid;
  v_count     integer;
BEGIN
  v_tenant_id := public.get_request_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_tenant_context';
  END IF;

  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.is_tenant_admin(v_tenant_id, v_caller_id) THEN
    RAISE EXCEPTION 'not_tenant_admin';
  END IF;

  -- Guard against removing the last admin. Once a tenant has explicit
  -- admins, removing them all would brick the tenant (bootstrap fallback
  -- only kicks in when zero rows exist — we'd need to also delete the
  -- last row in the same transaction, which is the DELETE we're rejecting).
  SELECT COUNT(*) INTO v_count
    FROM public.tenant_admins WHERE tenant_id = v_tenant_id;
  IF v_count <= 1 THEN
    RAISE EXCEPTION 'cannot_remove_last_admin'
      USING HINT = 'Add another admin first; you cannot leave a tenant with zero admins';
  END IF;

  DELETE FROM public.tenant_admins
   WHERE tenant_id = v_tenant_id AND user_id = p_user_id;

  INSERT INTO public.audit_log (tenant_id, actor, action, target_type, target_id)
  VALUES (
    v_tenant_id,
    'user:' || v_caller_id::text,
    'tenant_admin_removed',
    'user',
    p_user_id
  );
END;
$$;


-- ─── 6 · Update update_tenant_settings to use is_tenant_admin ──────────
CREATE OR REPLACE FUNCTION public.update_tenant_settings(
  p_display_name text DEFAULT NULL,
  p_accent_hex   text DEFAULT NULL,
  p_local_number text DEFAULT NULL,
  p_union_type   text DEFAULT NULL
)
RETURNS public.tenants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, auth
AS $$
DECLARE
  v_tenant_id    uuid;
  v_user_id      uuid;
  v_user_email   text;
  v_result       public.tenants%ROWTYPE;
  v_changed      jsonb;
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
    RAISE EXCEPTION 'not_tenant_admin'
      USING HINT = 'You are not an admin of this tenant. Ask an existing admin to add you via add_tenant_admin.';
  END IF;

  UPDATE public.tenants
     SET display_name = COALESCE(NULLIF(trim(p_display_name), ''), display_name),
         accent_hex   = COALESCE(NULLIF(trim(p_accent_hex),   ''), accent_hex),
         local_number = COALESCE(NULLIF(trim(p_local_number), ''), local_number),
         union_type   = COALESCE(NULLIF(trim(p_union_type),   ''), union_type),
         updated_at   = NOW()
   WHERE id = v_tenant_id
   RETURNING * INTO v_result;

  v_changed := jsonb_strip_nulls(jsonb_build_object(
    'display_name', p_display_name,
    'accent_hex',   p_accent_hex,
    'local_number', p_local_number,
    'union_type',   p_union_type
  ));

  -- Resolve email for the audit record (best-effort; auth.users may have
  -- been deleted between auth.uid() and now, in which case email is NULL).
  SELECT email INTO v_user_email FROM auth.users WHERE id = v_user_id;

  INSERT INTO public.audit_log (
    tenant_id, actor, action, target_type, target_id, detail
  )
  VALUES (
    v_tenant_id,
    'user:' || v_user_id::text,
    'tenant_settings_updated',
    'tenant',
    v_tenant_id,
    jsonb_build_object('actor_email', v_user_email, 'changed', v_changed)
  );

  RETURN v_result;
END;
$$;


-- ─── 7 · Backfill from contact_email pairs ─────────────────────────────
-- For each tenant whose contact_email matches an existing auth.users.email,
-- create the tenant_admins row. Idempotent via ON CONFLICT.
INSERT INTO public.tenant_admins (tenant_id, user_id, role, created_by)
SELECT t.id, u.id, 'admin', NULL
  FROM public.tenants t
  JOIN auth.users u ON lower(u.email) = lower(t.contact_email)
ON CONFLICT (tenant_id, user_id) DO NOTHING;


-- ─── 8 · Grants ────────────────────────────────────────────────────────
REVOKE EXECUTE ON FUNCTION public.is_tenant_admin(uuid, uuid)        FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.add_tenant_admin(text)             FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.remove_tenant_admin(uuid)          FROM PUBLIC;

GRANT  EXECUTE ON FUNCTION public.is_tenant_admin(uuid, uuid)        TO authenticated;
GRANT  EXECUTE ON FUNCTION public.add_tenant_admin(text)             TO authenticated;
GRANT  EXECUTE ON FUNCTION public.remove_tenant_admin(uuid)          TO authenticated;


-- ─── 9 · Comments ──────────────────────────────────────────────────────
COMMENT ON TABLE  public.tenant_admins             IS 'Membership: which auth.users are admins of which tenants. v1 has one role (admin); future roles slot into the CHECK.';
COMMENT ON COLUMN public.tenant_admins.created_by  IS 'Who added this admin. NULL for backfilled rows (migration 0006 had no caller context).';
COMMENT ON FUNCTION public.add_tenant_admin(text)  IS 'Invite an existing auth.users by email. Caller must already be a tenant admin. Auto-promotes caller from bootstrap fallback if needed.';
COMMENT ON FUNCTION public.remove_tenant_admin(uuid) IS 'Remove an admin. Refuses if it would leave the tenant with zero admins.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- The membership table exists with RLS forced:
--   SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class
--    WHERE relname = 'tenant_admins';
--
--   -- Backfilled rows for tenants whose contact_email had signed in:
--   SELECT t.slug, t.contact_email, u.email, ta.created_by
--     FROM public.tenant_admins ta
--     JOIN public.tenants t ON t.id = ta.tenant_id
--     JOIN auth.users u    ON u.id = ta.user_id
--    ORDER BY t.slug;
--
--   -- Bootstrap fallback still works for tenants whose contact_email
--   -- hasn't signed in yet (they'll show as 0 backfilled rows but
--   -- is_tenant_admin returns true on first sign-in):
--   SELECT t.slug, t.contact_email,
--          EXISTS (SELECT 1 FROM public.tenant_admins WHERE tenant_id = t.id) AS has_explicit
--     FROM public.tenants t
--    ORDER BY t.slug;
--
--   -- Try the new RPC. Authenticated as an existing admin:
--   SELECT public.add_tenant_admin('coworker@example.org');
--   -- → returns the new tenant_admins row OR raises user_not_signed_in_yet
--
-- Known follow-ups:
--   · Admin "team" page UI at /admin/team that lists current admins,
--     supports add (calls add_tenant_admin), and supports remove (calls
--     remove_tenant_admin with the "can't remove yourself if you're last"
--     guard exposed in the UI).
--   · 'viewer' role (read-only) — needs the CHECK constraint extended
--     and is_tenant_admin to distinguish "is admin" from "has access".
--   · Magic-link invitation: when add_tenant_admin raises
--     user_not_signed_in_yet, the UI could trigger a magic-link to the
--     email so the recipient lands on /admin/signin, completes the
--     bootstrap, and the inviter retries the add.
-- ════════════════════════════════════════════════════════════════════════
