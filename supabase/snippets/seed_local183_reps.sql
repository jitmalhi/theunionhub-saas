-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub Access · snippet — seed three credential tiers into Local 183
-- ════════════════════════════════════════════════════════════════════════
-- One-off CLOUD seed (run in the Supabase SQL Editor). NOT part of the dev
-- seed.sql, which targets the 'demo' tenant — this targets the live 'local183'
-- tenant so the role badges can be demoed on real cards.
--
-- Seeds one rep per tier so all three badge treatments are visible:
--     executive     → filled accent chip
--     unit_officer  → outlined chip
--     steward       → outlined chip
--
-- Design choices, matching launch reality (migration 0013):
--   · user_id IS NULL — reps are pre-created by an admin and a permanent QR is
--     printed before the person ever signs in. They can self-claim later by
--     magic-link (email match → claim_representative()).
--   · email is set so the future self-claim has something to match on.
--   · ids are PINNED (a57e0a00-…-0010/0011/0012) so the /access/<id> URLs are
--     stable and copy-pasteable into a deck or a QR generator.
--
-- Tenant is resolved by slug (never a literal id) so this is safe to paste as-is.
-- Idempotent: ON CONFLICT (id) DO UPDATE — re-running refreshes the rows.
-- (The 0016 role-guard trigger does not block this: in the SQL Editor
-- auth.uid() is NULL, which the guard treats as trusted/server context.)
-- ════════════════════════════════════════════════════════════════════════

WITH t AS (
  SELECT id AS tenant_id FROM public.tenants WHERE slug = 'local183'
)
INSERT INTO public.stewards (
  id, tenant_id, user_id,
  full_name, title, role, email, phone, worksite, bio,
  status, appointed_at
)
SELECT
  v.id, t.tenant_id, NULL,
  v.full_name, v.title, v.role, v.email, v.phone, v.worksite, v.bio,
  'active', v.appointed_at
FROM t, (VALUES
  (
    'a57e0a00-0000-4000-8000-000000000010'::uuid,
    'Eleanor Vance', 'Local President', 'executive',
    'eleanor.vance@local183.theunionhub.com', '+1-555-0183',
    'Local 183 · Executive Board',
    'President of Local 183. Here for contract questions, member concerns, and anything I can do to back you up on the floor.',
    '2016-03-01'::date
  ),
  (
    'a57e0a00-0000-4000-8000-000000000011'::uuid,
    'Marcus Bell', 'Unit Chair', 'unit_officer',
    'marcus.bell@local183.theunionhub.com', '+1-555-0184',
    'Distribution Center · Unit 4',
    'Unit Chair for the Distribution Center. Bring me scheduling disputes, overtime issues, and health-and-safety concerns.',
    '2020-09-14'::date
  ),
  (
    'a57e0a00-0000-4000-8000-000000000012'::uuid,
    'Priya Anand', 'Shop Steward', 'steward',
    'priya.anand@local183.theunionhub.com', '+1-555-0185',
    'Warehouse · Night Shift',
    'Night-shift steward in the warehouse. Reach out about grievances, breaks, or anything that needs a rep in your corner.',
    '2022-01-10'::date
  )
) AS v(id, full_name, title, role, email, phone, worksite, bio, appointed_at)
ON CONFLICT (id) DO UPDATE
  SET tenant_id    = EXCLUDED.tenant_id,
      full_name    = EXCLUDED.full_name,
      title        = EXCLUDED.title,
      role         = EXCLUDED.role,
      email        = EXCLUDED.email,
      phone        = EXCLUDED.phone,
      worksite     = EXCLUDED.worksite,
      bio          = EXCLUDED.bio,
      status       = EXCLUDED.status,
      appointed_at = EXCLUDED.appointed_at;

-- ─── Verify (read-only) ─────────────────────────────────────────────────
SELECT full_name, role, title, status
  FROM public.stewards
 WHERE tenant_id = (SELECT id FROM public.tenants WHERE slug = 'local183')
 ORDER BY CASE role
            WHEN 'executive'    THEN 1
            WHEN 'unit_officer' THEN 2
            WHEN 'steward'      THEN 3
            ELSE 4
          END;
-- Expect three rows: Eleanor Vance (executive), Marcus Bell (unit_officer),
-- Priya Anand (steward).
