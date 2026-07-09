-- =============================================================================
-- 0032_member_number.sql · Human-readable member number (display-only)
-- =============================================================================
-- Harvested from member-id-system (the `M-100823` card number) into the live
-- multi-tenant members table.
--
-- WHAT THIS IS: a human-readable identifier for display / print / read-aloud
-- ("what's your member number?"). It is NOT a lookup key. All lookups and the
-- QR / verify URLs continue to key on the opaque `members.id` (uuid) — see
-- lookup_member (0008/0033). member_number is deliberately NOT unique globally,
-- only per tenant, and never appears in a URL an attacker could enumerate.
--
-- Numbering slot: 0031 is RESERVED for the members RLS hardening (D5) per
-- docs/BACKLOG.md; identity-harvest migrations take 0032+.
--
-- Depends on: 0002 (public.members, tenant_id).
-- Idempotent. After applying: NOTIFY pgrst, 'reload schema';
-- =============================================================================

BEGIN;

-- ─── 1 · Column ─────────────────────────────────────────────────────────────
ALTER TABLE public.members
  ADD COLUMN IF NOT EXISTS member_number text;

-- ─── 2 · Per-tenant uniqueness ──────────────────────────────────────────────
-- Unique only WHERE present, and only WITHIN a tenant: two locals may both
-- issue "M-000001". Partial so existing NULL rows never collide during backfill.
CREATE UNIQUE INDEX IF NOT EXISTS uq_members_tenant_member_number
  ON public.members (tenant_id, member_number)
  WHERE member_number IS NOT NULL;

-- ─── 3 · Backfill ───────────────────────────────────────────────────────────
-- Default format (per-tenant, documented below): 'M-' + a six-digit,
-- zero-padded sequence assigned in row-creation order within each tenant.
-- A tenant may later adopt its own scheme; uniqueness is enforced per tenant
-- by the index above, not by this format.
--
-- ONE-SHOT ONLY — do NOT re-run this backfill to number new members. It
-- restarts row_number() at 1 per tenant, so on a second run it would try to
-- assign 'M-000001' again and abort on the unique index. Ongoing assignment is
-- handled by the 0035 trigger (per-tenant counter seeded above this backfill's
-- max); after 0035 no member row is left NULL, so re-running this is a no-op
-- anyway.
WITH numbered AS (
  SELECT
    id,
    'M-' || lpad(
      (row_number() OVER (PARTITION BY tenant_id ORDER BY created_at, id))::text,
      6, '0'
    ) AS assigned
  FROM public.members
  WHERE member_number IS NULL
)
UPDATE public.members m
   SET member_number = n.assigned
  FROM numbered n
 WHERE m.id = n.id;

-- ─── 4 · Documentation ──────────────────────────────────────────────────────
COMMENT ON COLUMN public.members.member_number IS
  'Human-readable member number for display/print/read-aloud ONLY. Unique per '
  'tenant (uq_members_tenant_member_number), NOT a lookup key — all lookups and '
  'QR/verify URLs key on members.id (uuid). Default backfill format: '
  'M-<6-digit per-tenant sequence>; tenants may adopt their own format later '
  '(uniqueness is per-tenant, not format-bound).';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--   -- Every member has a number, unique within its tenant?
--   SELECT tenant_id, count(*), count(DISTINCT member_number)
--     FROM public.members GROUP BY tenant_id;   -- the two counts must match
--
--   -- No global-uniqueness assumption leaked in (two tenants CAN share one):
--   SELECT member_number, count(*) FROM public.members
--    GROUP BY member_number HAVING count(*) > 1;  -- rows here are EXPECTED/fine
-- ════════════════════════════════════════════════════════════════════════════
