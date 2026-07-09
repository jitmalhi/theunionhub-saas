-- =============================================================================
-- 0035_member_number_autoassign.sql · Assign member_number on every insert
-- =============================================================================
-- 0032 added members.member_number and BACKFILLED existing rows, but nothing
-- assigns it going forward — admin_add_member (0009), the bulk importer, and
-- lib/admin-members.js never set it, so every member created after 0032 would
-- render "Member No. —" on the card. This closes that gap with a BEFORE INSERT
-- trigger that assigns a per-tenant sequential number when one isn't supplied,
-- collision-safe via an atomic per-tenant counter (not a max()+1 race, and not
-- the naive re-run of the 0032 backfill, which would restart at M-000001 and
-- collide on the unique index).
--
-- A tenant that adopts its own numbering just supplies member_number explicitly
-- on insert; the trigger only fills NULLs, so custom schemes are untouched.
--
-- Depends on: 0002 (members), 0032 (members.member_number + unique index).
-- Idempotent. After applying: NOTIFY pgrst, 'reload schema';
-- =============================================================================

BEGIN;

-- ─── 1 · Per-tenant counter ─────────────────────────────────────────────────
-- One row per tenant holding the next sequence value. Written only by the
-- SECURITY DEFINER trigger below (and service_role); RLS forced with no
-- policies so anon/authenticated can neither read nor tamper with it.
CREATE TABLE IF NOT EXISTS public.member_number_counters (
  tenant_id uuid   PRIMARY KEY REFERENCES public.tenants(id) ON DELETE CASCADE,
  next_seq  bigint NOT NULL DEFAULT 1
);

ALTER TABLE public.member_number_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_number_counters FORCE  ROW LEVEL SECURITY;
-- (no policies: only the definer trigger and service_role touch this table)

-- ─── 2 · Seed the counter above the highest backfilled number per tenant ────
-- 0032 assigned 'M-<6-digit>' in creation order. Parse those to seed next_seq =
-- max + 1 so the trigger never re-issues an existing number. Only rows matching
-- the default format are considered; custom-format numbers are ignored here.
INSERT INTO public.member_number_counters (tenant_id, next_seq)
SELECT m.tenant_id,
       COALESCE(MAX(NULLIF(regexp_replace(m.member_number, '^M-0*', ''), ''))::bigint, 0) + 1
  FROM public.members m
 WHERE m.tenant_id IS NOT NULL
   AND m.member_number ~ '^M-\d+$'
 GROUP BY m.tenant_id
ON CONFLICT (tenant_id)
  DO UPDATE SET next_seq = GREATEST(public.member_number_counters.next_seq, EXCLUDED.next_seq);

-- ─── 3 · Assignment trigger ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.assign_member_number()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_seq bigint;
BEGIN
  -- Respect an explicitly supplied number (custom tenant scheme); only fill
  -- NULLs. Can't number without a tenant — leave NULL and let the caller fail
  -- the NOT NULL/tenant checks elsewhere rather than mis-assign.
  IF NEW.member_number IS NOT NULL OR NEW.tenant_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Ensure a counter row exists, then atomically claim the next value. The
  -- UPDATE … RETURNING is race-safe: concurrent inserts serialise on the row.
  INSERT INTO public.member_number_counters (tenant_id, next_seq)
    VALUES (NEW.tenant_id, 1)
    ON CONFLICT (tenant_id) DO NOTHING;

  UPDATE public.member_number_counters
     SET next_seq = next_seq + 1
   WHERE tenant_id = NEW.tenant_id
   RETURNING next_seq - 1 INTO v_seq;

  NEW.member_number := 'M-' || lpad(v_seq::text, 6, '0');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS members_assign_member_number ON public.members;
CREATE TRIGGER members_assign_member_number
  BEFORE INSERT ON public.members
  FOR EACH ROW
  EXECUTE FUNCTION public.assign_member_number();

COMMENT ON TABLE public.member_number_counters IS
  'Per-tenant next-sequence counter backing members.member_number auto-assign '
  '(0035). Written only by assign_member_number() (SECURITY DEFINER) + '
  'service_role; RLS forced with no policies.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--   -- New member with no member_number gets the next per-tenant value:
--   INSERT INTO public.members (tenant_id, full_name, status)
--     VALUES ((SELECT id FROM tenants WHERE slug='demo'), 'Trigger Test', 'active')
--     RETURNING member_number;   -- → 'M-0000NN' (max existing + 1)
--
--   -- Explicit number is respected (custom scheme):
--   INSERT INTO public.members (tenant_id, full_name, member_number)
--     VALUES ((SELECT id FROM tenants WHERE slug='demo'), 'Custom', 'ABC-1')
--     RETURNING member_number;   -- → 'ABC-1'
-- ════════════════════════════════════════════════════════════════════════════
