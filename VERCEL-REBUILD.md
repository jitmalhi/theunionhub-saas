# Vercel Rebuild — Steward App (clean setup)

_Old Vercel project `the-union-hub-online` was deleted 2026-06-30. Code (`main`)
and Supabase are untouched. This rebuilds hosting cleanly, connected to `main`,
with one deploy path (git push). ~20–30 min._

Repo: `github.com/jitmalhi/theunionhub-saas` · Production branch: `main`
Supabase (unchanged): `frdvhmzbsmczknqtexvx`

---

## Step 1 — Import the repo as a new project

- [ ] Vercel → **Add New… → Project → Import Git Repository**
- [ ] Choose **`jitmalhi/theunionhub-saas`** (authorize GitHub if prompted)
- [ ] Project name: `the-union-hub` (or reuse the old name — it's freed now)

## Step 2 — Build settings (it's a NO-BUILD static app)

- [ ] **Framework Preset:** `Other`
- [ ] **Root Directory:** `./` (repo root)
- [ ] **Build Command:** leave empty / OFF (repo's is `echo 'No build step needed'`)
- [ ] **Output Directory:** leave empty (serves repo root)
- [ ] **Install Command:** default is fine

> Why: `vercel.json` sets `framework: null`, `buildCommand: null`. There is no
> build — Vercel just serves the static files + runs `/api/*` and the edge
> middleware.

## Step 3 — Environment variables (Production + Preview)

Add these three (Settings → Environment Variables). Do NOT set
`PUBLIC_BASE_DOMAIN` — leaving it unset lets the per-host registry drive both
`.com` and (future) `.ca`.

- [ ] `SUPABASE_URL` = `https://frdvhmzbsmczknqtexvx.supabase.co`
- [ ] `SUPABASE_ANON_KEY` = `sb_publishable_mQ5Y9tjHHQmc9gCZPB_tHA_OwHXTc9P`
- [ ] `SUPABASE_SERVICE_ROLE_KEY` = the `service_role` JWT
      (Supabase → Project Settings → API → `service_role`; decoded payload says
      `"role":"service_role"`). This is the one that unblocks DFR + scan writes.

## Step 4 — First deploy

- [ ] Click **Deploy**. It should build in seconds (no build step).
- [ ] Note the `*.vercel.app` URL it gives you.

## Step 5 — Domains (CRITICAL: the wildcard)

Multi-tenant subdomains (`local183.theunionhub.ca`) require the wildcard.

- [ ] Settings → **Domains** → add `theunionhub.ca`
- [ ] Add **`*.theunionhub.ca`**  ← the wildcard; without it, tenant subdomains
      silently 404
- [ ] Follow Vercel's DNS instructions. If your registrar's DNS already points at
      Vercel from before, it may verify instantly; otherwise add the shown
      records (usually a CNAME/A for apex + a CNAME `*` for the wildcard).
- [ ] (Skip `.ca` domains for now — only when the Canadian project exists.)

## Step 6 — Verify

- [ ] `curl -s https://theunionhub.ca/api/health` → `200` / `ready:true`
- [ ] `curl -s https://local183.theunionhub.ca/api/health` → `200`
      (proves the wildcard + tenant routing work)
- [ ] Open `https://local183.theunionhub.ca/admin` → magic-link login loads
- [ ] DFR smoke test: `https://local183.theunionhub.ca/meet/a57e0a00-0000-4000-8000-000000000010`
      → submit → `201` → row appears in `/admin/activity`

---

## Step 7 — The discipline that prevents the old "reverts to old files" bug

- [ ] **Deploy ONLY by pushing to `main`.** Every push auto-deploys.
- [ ] **Stop using `vercel deploy --prod` from the CLI.** Mixing CLI deploys with
      git auto-deploys is what made prod feel like it reverted. One source of
      truth = the `main` branch on GitHub.
- [ ] (Optional) delete the `deploy` script from `package.json` so no one runs it
      by habit.

---

## Later — the other two apps (each its own Vercel project)

`grievance-system` and `member-id-system` are separate deployables and are NOT on
GitHub yet. When ready (weeks 2–3), for each:

1. Create a GitHub repo, push the app to it.
2. Vercel → Import → that repo. Framework preset **Vite** (these DO build:
   `npm run build` → `dist/`), Output `dist`.
3. Add their env vars (`VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`).
4. Add a domain/subdomain, deploy, verify.

Recommendation: **3 separate repos → 3 Vercel projects** (simplest isolation).

---

_Last updated: 2026-06-30._
