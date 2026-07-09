# Steward System — Go-Live Checklist

_Spearhead app for the 30-day goal (target ~2026-07-29). Drive THIS to genuinely
live first; grievance + member-id are demo-state work (see bottom)._

Project: `steward-system` (static + `@vercel/edge`, Supabase).
Supabase project: `frdvhmzbsmczknqtexvx` (physical region: **ca-central-1**; the `region:'us'` label in `lib/domains.js` is an env-namespace key, not the DB region). Demo tenant: `local183`.

---

## 0. The one real blocker — service-role key in Vercel  ⏱️ ~5 min

The DFR writer (`/api/log-interaction`) and scan analytics (`/api/access-event`)
bypass RLS and need the secret service-role key. It's already in local
`.env.local`; production needs it in Vercel.

- [ ] Vercel → project → **Settings → Environment Variables**
- [ ] Add `SUPABASE_SERVICE_ROLE_KEY` = the `service_role` JWT
      (Supabase → Project Settings → API → `service_role`; decoded payload must
      say `"role":"service_role"`). Scope: **Production + Preview**.
- [ ] **Redeploy** (env changes don't apply to existing deployments).
- [ ] Verify: `curl -s https://local183.theunionhub.com/api/health` → `200` /
      `ready:true` (was `503`).

> Scope note: the plain (unsuffixed) var drives only the default `.com` region.
> `.ca` would need `SUPABASE_SERVICE_ROLE_KEY_CA` — no leak risk.

---

## 1. End-to-end browser smoke test  ⏱️ ~20 min

Do this with a REAL magic-link session (nothing here was browser-verified yet).

- [ ] **Admin login:** open `local183.theunionhub.com/admin`, request magic link,
      sign in as a tenant admin. Confirm Dashboard loads.
- [ ] **Admin pages render:** Members · Grievances · Intelligence · Team · Audit ·
      Settings · Access — each loads without console errors.
- [ ] **DFR write path (the key test):** open
      `local183.theunionhub.com/meet/a57e0a00-0000-4000-8000-000000000010`
      (seeded steward Eleanor Vance) → complete the 3-step interaction → expect
      `201`.
- [ ] **Confirm it landed:** new row in `/admin/activity`, and the count bumps in
      `/admin/intelligence`.
- [ ] **Steward portal:** sign in as a steward, open `/access/portal/card`
      (flip card + QR), and `/access/portal/knowledge` (capture + transfer).
- [ ] **Public card:** scan/open a representative's `access.html` card — tier
      badge + vCard download work.

---

## 2. Remaining verification  ⏱️ ~15 min

- [ ] **0016 trigger negative-test:** as a NON-admin steward session, attempt to
      change `stewards.role` → must be rejected (escalation guard). Needs an
      authed steward session, so do it in-browser/REST.
- [ ] **PostgREST schema cache:** if any new table/RPC 404s over REST right after
      a migration, run `NOTIFY pgrst, 'reload schema';` in the SQL editor.

---

## 3. Product decision — notifications

The member-view success copy is deliberately "…now on record for your union
representative" (no false "notified" claim).

- [ ] Decide: keep recorded-only (ship as-is), **or** wire a provider
      (email/SMS/push) before launch. Not a blocker; a scope call.

---

## 4. After steward is confirmed live

- [ ] Delete the empty husk `C:\TheUnionHub_online` (reopen VSCode on
      `C:\X\steward-system` first to release the lock).
- [ ] Delete the original `C:\theunionhub-saas` (fully archived at
      `C:\X\_archive\theunionhub-saas-backup-2026-06-29.zip`). The public
      `app/*.html` are intentional Phase-0 placeholders; the old full marketing
      pages live in that zip if ever needed.
- [ ] `.ca`: only stand up the Canadian Supabase project if a customer needs it
      (fill the `.ca` entry in `lib/domains.js`, set `SUPABASE_*_CA`, apply all
      migrations to the CA project).

---

## Weeks 2–3 — bring the other two to demo state (turnkey)

**Grievance system** (`C:\X\grievance-system`, Vite + React) — per its handoff,
never run against live Supabase or a browser:
1. Create a Supabase project (or local `supabase start`).
2. `supabase db reset` → applies `supabase/migrations/` + `supabase/seed.sql`.
3. `cp .env.example .env`; set `VITE_SUPABASE_URL` + `VITE_SUPABASE_ANON_KEY`.
4. `npm run dev` → browser-verify the capture→retrieve loop
   (`GrievanceDebriefForm` + `CBAArticleBrowser` — its demo heart).

**Member-ID system** (`C:\X\member-id-system`, Vite + React) — runs in demo mode
now; to go live:
1. Create/reuse a Supabase project; apply `supabase/migrations/0001_members.sql`
   in the SQL editor, then `NOTIFY pgrst, 'reload schema';`.
2. `cp .env.example .env`; set `VITE_SUPABASE_URL` + `VITE_SUPABASE_ANON_KEY`.
3. `npm run dev` → browser-verify `/card/M-100823` and `/verify/M-999000`.
4. Decide: standalone product, or a feature of steward/grievance.

---

_Last updated: 2026-06-29. See `HANDOFF.md` for full build history._
