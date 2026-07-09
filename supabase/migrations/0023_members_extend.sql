-- =============================================================================
-- 0023_members_extend.sql
-- Fold grievance-system's richer member model into the LIVE members table
-- (decision D1: keep live `status` untouched; ADD `membership_status` + fields).
-- Adds field-level audit (member_history). No parallel members table.
--
-- Depends on: 0002 (members, get_request_tenant_id), 0022 (is_request_tenant_member).
-- Discarded from grievance-system: its `members` CREATE (folded here as ALTERs).
-- =============================================================================

-- membership_status enum (grievance lifecycle) — additive; live `status` stays.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'membership_status') THEN
    CREATE TYPE public.membership_status AS ENUM ('ACTIVE', 'RETIRED', 'ON_LEAVE', 'TERMINATED');
  END IF;
END $$;

-- Extend live members with the grievance fields (all idempotent).
ALTER TABLE public.members
  ADD COLUMN IF NOT EXISTS employee_id        text,
  ADD COLUMN IF NOT EXISTS first_name         text,
  ADD COLUMN IF NOT EXISTS last_name          text,
  ADD COLUMN IF NOT EXISTS email              text,
  ADD COLUMN IF NOT EXISTS phone_number       text,
  ADD COLUMN IF NOT EXISTS job_classification text,
  ADD COLUMN IF NOT EXISTS department         text,
  ADD COLUMN IF NOT EXISTS location           text,
  ADD COLUMN IF NOT EXISTS seniority_date     date,
  ADD COLUMN IF NOT EXISTS membership_status  public.membership_status NOT NULL DEFAULT 'ACTIVE',
  ADD COLUMN IF NOT EXISTS custom_attributes  jsonb NOT NULL DEFAULT '{}'::jsonb;

-- Partial unique constraints (only where the value is present, so existing rows
-- with NULL employee_id/email don't collide).
CREATE UNIQUE INDEX IF NOT EXISTS uq_members_tenant_employee
  ON public.members (tenant_id, employee_id) WHERE employee_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_members_tenant_email
  ON public.members (tenant_id, email) WHERE email IS NOT NULL;

-- -----------------------------------------------------------------------------
-- member_history — field-level audit (append-only).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.member_history (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  member_id     uuid        NOT NULL REFERENCES public.members(id) ON DELETE CASCADE,
  changed_by    uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  field_changed text        NOT NULL,
  old_value     text,
  new_value     text,
  changed_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_member_history_member ON public.member_history (member_id);
CREATE INDEX IF NOT EXISTS idx_member_history_tenant ON public.member_history (tenant_id);

-- Audit trigger. SECURITY DEFINER; explicit tenant guard uses the LIVE resolver
-- (get_request_tenant_id) — a service/cron context has no header → guard skipped.
CREATE OR REPLACE FUNCTION public.log_member_change()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_tenant uuid := public.get_request_tenant_id();
  v_old jsonb := to_jsonb(old);
  v_new jsonb := to_jsonb(new);
  v_key text;
BEGIN
  IF v_caller_tenant IS NOT NULL AND new.tenant_id IS DISTINCT FROM v_caller_tenant THEN
    RAISE EXCEPTION 'tenant mismatch in member audit (row % vs caller %)',
      new.tenant_id, v_caller_tenant USING errcode = 'check_violation';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(v_new) LOOP
    IF v_key IN ('updated_at') THEN CONTINUE; END IF;
    IF v_old -> v_key IS DISTINCT FROM v_new -> v_key THEN
      INSERT INTO public.member_history
        (tenant_id, member_id, changed_by, field_changed, old_value, new_value)
      VALUES
        (new.tenant_id, new.id, auth.uid(), v_key, v_old ->> v_key, v_new ->> v_key);
    END IF;
  END LOOP;

  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS trg_members_audit ON public.members;
CREATE TRIGGER trg_members_audit
  AFTER UPDATE ON public.members
  FOR EACH ROW EXECUTE FUNCTION public.log_member_change();

-- Append-only: block edits/deletes to history even for elevated roles.
CREATE OR REPLACE FUNCTION public.prevent_member_history_mutation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'member_history is append-only (% blocked)', tg_op
    USING errcode = 'restrict_violation';
END;
$$;
DROP TRIGGER IF EXISTS trg_member_history_no_update ON public.member_history;
DROP TRIGGER IF EXISTS trg_member_history_no_delete ON public.member_history;
CREATE TRIGGER trg_member_history_no_update BEFORE UPDATE ON public.member_history
  FOR EACH ROW EXECUTE FUNCTION public.prevent_member_history_mutation();
CREATE TRIGGER trg_member_history_no_delete BEFORE DELETE ON public.member_history
  FOR EACH ROW EXECUTE FUNCTION public.prevent_member_history_mutation();

-- RLS: header tenant + membership. Inserts happen via the definer trigger only.
ALTER TABLE public.member_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_history FORCE  ROW LEVEL SECURITY;

CREATE POLICY member_history_select ON public.member_history
  FOR SELECT TO authenticated
  USING (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_member());

GRANT SELECT ON public.member_history TO authenticated;

-- NOTE (backlog): the live `members` RLS is header-only (tenant_id = header).
-- Per D5, harden it to also require is_request_tenant_member() in a follow-up —
-- deferred here because it changes existing live-app behavior. See docs/BACKLOG.md.
--
-- After applying: NOTIFY pgrst, 'reload schema';
