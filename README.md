# The Union Hub — SaaS Platform

> The system of record for who is a union member, right now.
> No app. No password. Verified in seconds.

This repository is the **multi-tenant SaaS rebuild** of [theunionhub.com](https://theunionhub.com). It supersedes the single-tenant static prototype at `C:\Theunionhub` and is engineered for horizontal scale across unions (locals, districts, internationals) on **Vercel + Supabase**.

Brand discipline is non-negotiable. Tokens, type, and layout rules in this README are derived directly from the canonical brand book at [Brand/brandbook.html](Brand/brandbook.html). If a colour, font, or radius isn't listed here, it doesn't ship.

---

## 1 · Status

| Item                | Current                              | Target                                                                 |
| ------------------- | ------------------------------------ | ---------------------------------------------------------------------- |
| Hosting             | Apache (`.htaccess`)                 | Vercel (Edge + Serverless)                                             |
| Tenancy             | Single-tenant prototype              | Multi-tenant, subdomain-routed (`<slug>.theunionhub.com`)              |
| Backend             | Supabase project `frdvhmzbsmczknqtexvx` (shared) | Supabase with strict RLS per `tenant_id`                        |
| Frontend            | Hand-rolled HTML + 3 JS files        | Vanilla HTML + ES modules, no build step (deliberate)                  |
| Secrets             | Anon key hardcoded in `js/live.js`   | Env-driven Supabase client, public anon key per tenant via API route   |
| Auth                | None                                 | Supabase magic-link, member self-verify only — no passwords            |
| Deployment surface  | 1 site                               | Marketing site (root) + N tenant apps (subdomain) + shared admin       |

The migration is **clean-slate at the file layout**; the Supabase project is **evolved, not replaced** (existing `members` table and seeded demo IDs `550bc413…`, `21e63983…`, `fd1be966…` remain valid during cutover).

---

## 2 · Technical Stack

### Edge & Hosting
- **Vercel** — static assets, serverless API routes, edge middleware for subdomain → tenant resolution.
- **Wildcard DNS** — `*.theunionhub.com` → Vercel; the root (`theunionhub.com`, `www.`) serves the marketing site.
- **No build step (Phase 1)** — vanilla HTML + ES modules served direct. A bundler is permitted later only if a real constraint appears.

### Backend
- **Supabase Postgres** — single project, tenant isolation via `tenant_id` column + Row-Level Security policies.
- **Supabase Auth** — magic-link only. Members never set a password.
- **Supabase Realtime** — live counts on `members`, `verifications`, `audit_log`.
- **Supabase Storage** — tenant logos, member photos (if any), each bucket scoped by tenant.

### Frontend
- **Vanilla HTML + ES modules** — no framework. The brand is editorial; the markup is too.
- **CSS custom properties only** — design tokens in [styles/tokens.css](styles/tokens.css). No Sass, no Tailwind, no utility-class soup.
- **Progressive enhancement** — every page renders without JS; live features attach only when their markup exists (pattern established by `js/live.js`).

### Tooling (kept minimal)
- `git` — version control, conventional commits.
- `npm` — only for `vercel`, `supabase` CLIs and local dev server. No runtime npm deps.
- **No CSS preprocessor. No JS bundler. No CSS-in-JS.**

---

## 3 · Multi-Tenant Directory Structure

```
theunionhub-saas/
├── README.md                        ← you are here
├── .gitignore
├── .env.local.example               ← committed template; .env.local is gitignored
├── package.json                     ← dev scripts only (vercel, supabase)
├── vercel.json                      ← rewrites, edge middleware, headers
│
├── public/                          ← served at root, cached aggressively
│   ├── favicon.ico, favicon-16.png, favicon-32.png, apple-touch-icon.png
│   ├── logo.svg
│   ├── og-image.png
│   ├── robots.txt
│   └── sitemap.xml
│
├── styles/                          ← single source of truth for all CSS
│   ├── tokens.css                   ← design tokens (colour, type, spacing)
│   ├── reset.css                    ← minimal normalize
│   ├── base.css                     ← body, headings, links
│   └── components.css               ← .btn, .pill, .card, .util, .nav, etc.
│
├── app/                             ← public marketing site (root domain)
│   ├── index.html
│   ├── about.html
│   ├── contact.html
│   ├── status.html
│   ├── audit-log.html
│   ├── privacy.html
│   ├── terms.html
│   ├── data-processing.html
│   ├── security.html
│   └── 404.html
│
├── tenants/                         ← tenant-scoped application surfaces
│   ├── _template/                   ← reference layout — NEVER deployed as a tenant
│   │   ├── card.html                ← member digital card
│   │   ├── verify.html              ← public verification page
│   │   └── tenant.css               ← per-tenant overrides (logo, accent shift only)
│   └── README.md                    ← provisioning checklist
│
├── api/                             ← Vercel serverless / edge functions
│   ├── _middleware.js               ← edge: resolve subdomain → tenant_id, set header
│   ├── tenants/
│   │   ├── resolve.js               ← GET /api/tenants/resolve?host=…
│   │   └── [slug]/
│   │       ├── members.js           ← GET /api/tenants/:slug/members
│   │       └── verify.js            ← GET /api/tenants/:slug/verify/:id
│   ├── webhooks/
│   │   └── supabase.js              ← auth, audit-log mirrors
│   └── health.js
│
├── lib/                             ← shared ES modules (browser + edge)
│   ├── supabase.js                  ← client factory; reads NEXT_PUBLIC_SUPABASE_URL/KEY
│   ├── tenant.js                    ← hostname → slug → tenant_id resolution
│   ├── live.js                      ← refactored from js/live.js, tenant-aware
│   └── qrcode.js                    ← QR generation (existing)
│
├── supabase/                        ← schema as code
│   ├── migrations/
│   │   ├── 0001_init_tenants.sql           ← tenants table + slug uniqueness
│   │   ├── 0002_members_add_tenant_id.sql  ← evolve existing members table
│   │   ├── 0003_rls_policies.sql           ← strict tenant_id isolation
│   │   └── 0004_audit_log.sql
│   ├── seed.sql                            ← demo tenant + 3 demo members
│   └── config.toml
│
├── Brand/                           ← canonical brand book (read-only reference)
│   └── brandbook.html
│
└── scripts/
    ├── new-tenant.mjs               ← provisions a tenant: row + DNS check + welcome
    └── dev.mjs                      ← local static server with host header rewriting
```

**Tenancy contract:** every database row that belongs to a union has a `tenant_id uuid not null` column; every API route resolves the tenant from the host header in `api/_middleware.js` and stamps it on the request; every Supabase query runs under RLS that compares `auth.jwt() ->> 'tenant_id'` to the row's `tenant_id`. There is no application-level filtering — the database is the boundary.

---

## 4 · CSS Global Design Tokens

The canonical token sheet lives at [styles/tokens.css](styles/tokens.css) (to be created during scaffold). Every page imports it first. **No raw hex values in component CSS — ever.** Reference tokens or extend the token sheet.

### 4.1 · Colour

```css
:root {
  /* Brand greens */
  --forest:        #0F6E56;   /* primary; CTAs, links, brand mark */
  --active:        #1D9E75;   /* live state, hover on primary */
  --mint:          #E1F5EE;   /* soft tints, verified-state backgrounds */
  --deep-forest:   #0D1F1A;   /* dark surfaces, headings on light */

  /* Neutrals */
  --near-black:    #111111;
  --off-white:     #F5F4F1;   /* page background */
  --paper:         #FAF9F5;   /* panel background, code blocks */
  --mid-gray:      #888780;

  /* Semantic */
  --alert:         #E24B4A;   /* error, destructive, "don't" examples */
  --warn:          #C68A1B;   /* degraded state, caution */

  /* Text */
  --ink:           #111111;
  --ink-soft:      #2A2A2A;
  --muted:         #888780;

  /* Hairlines — the brand's structural unit */
  --hair:          rgba(0, 0, 0, 0.15);
  --hair-on-dark:  rgba(245, 244, 241, 0.18);
}
```

### 4.2 · Typography

```css
:root {
  --font-display:  'Playfair Display', Georgia, serif;   /* h1–h4, display, pull-quotes */
  --font-body:     'DM Sans', system-ui, -apple-system, sans-serif;
  --font-mono:     'DM Mono', ui-monospace, SFMono-Regular, monospace;

  /* Weight tokens — only these weights are loaded */
  /* Playfair Display: 400, 600, 700, 900 (+ italic 400, 700, 900) */
  /* DM Sans:          300, 400, 500, 700 */
  /* DM Mono:          400, 500 */
}
```

Body sets `font-family: var(--font-body); font-weight: 300; font-size: 16px; line-height: 1.65;`. Headings are always `--font-display`, italic emphasis (`<em>`) always shifts to `--forest`. Eyebrows, monospace labels, and meta data use `--font-mono` at 10.5–11px with `letter-spacing: 0.16em–0.18em; text-transform: uppercase;`.

### 4.3 · Spacing, Radius, Layout

```css
:root {
  --pad-x:         clamp(20px, 5vw, 88px);   /* horizontal page padding */
  --rad:           12px;                     /* default radius (cards, buttons) */
  --rad-sm:        8px;                      /* inputs, small pills */
  --wrap-max:      1240px;                   /* content max-width */
  --grid:          12;                       /* editorial grid columns */
}

.wrap { max-width: var(--wrap-max); margin: 0 auto; padding: 0 var(--pad-x); }
```

### 4.4 · Brand Discipline (hard rules)

These are not suggestions. The brand book enforces them; review will reject any commit that breaks them.

- **No `box-shadow`.** Anywhere. Depth comes from hairlines and contrast.
- **No `linear-gradient`, no `radial-gradient`.** Surfaces are flat.
- **Hairlines are `0.5px`.** Not 1px. Not `border: 1px solid #eee`. Use `--hair` or `--hair-on-dark`.
- **No emojis in UI copy** unless explicitly approved by the founder.
- **Italic = `--forest`.** Every `<em>` in a heading shifts colour.
- **Pulse animation** for live states uses the keyframe in `js/live.js` (`uhpulse`) — do not invent a new one.
- **`prefers-reduced-motion: reduce` is respected.** Strip the pulse, keep the state.

---

## 5 · Local Development

Prerequisites: Node 20+, `npm`, [Vercel CLI](https://vercel.com/docs/cli), [Supabase CLI](https://supabase.com/docs/guides/cli).

```bash
# 1 · clone & install dev deps (no runtime deps)
git clone <repo> && cd theunionhub-saas
npm install

# 2 · environment
cp .env.local.example .env.local
# fill: NEXT_PUBLIC_SUPABASE_URL, NEXT_PUBLIC_SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY

# 3 · run
vercel dev               # marketing site + API routes on localhost:3000
# tenant subdomains during dev: use lvh.me, e.g. http://demo.lvh.me:3000
```

To exercise multi-tenancy locally, `lvh.me` resolves all subdomains to `127.0.0.1` — use `http://demo.lvh.me:3000` for the seeded `demo` tenant.

---

## 6 · Deployment

- **Vercel:** connect this repo, set env vars in the project dashboard, configure custom domains (`theunionhub.com`, `*.theunionhub.com`).
- **Supabase:** migrations applied via `supabase db push` from CI. Anon key is public-safe (RLS enforces isolation); service-role key lives only in Vercel env vars, never in client code.
- **DNS:** wildcard CNAME `*.theunionhub.com → cname.vercel-dns.com`. Apex `A` record per Vercel docs.

---

## 7 · Migration Notes (from prototype)

The following items from `C:\Theunionhub` are **carried forward** and must be resolved during scaffold:

1. **`js/live.js`** — currently embeds Supabase URL and anon key as string literals (`frdvhmzbsmczknqtexvx`, `sb_publishable_…`). Migrate to `lib/supabase.js` reading from `import.meta.env` / runtime config injected by the edge middleware.
2. **`.htaccess`** — Apache-specific. Vercel uses `vercel.json` for rewrites, headers, redirects. The `.htaccess` rules (HTTPS redirect, 404 mapping, security headers) must be translated, not copied.
3. **`sitemap.xml` & `robots.txt`** — currently single-tenant. Generate per-tenant sitemaps at `/<tenant>/sitemap.xml` via API route.
4. **Demo member IDs** (`550bc413…`, `21e63983…`, `fd1be966…`) — seed into the `demo` tenant via `supabase/seed.sql`.
5. **Hardcoded copy** in `card.html`, `verify.html` — extract tenant-specific strings (org name, local number, contact email) into the `tenants` table, render server-side via API route.

---

## 8 · Ownership

- **Product & brand:** The Union Hub.
- **Founding team:** Jit Singh — `kdehaansingh@gmail.com`.
- **Backend project:** Supabase org / project `frdvhmzbsmczknqtexvx` (to be renamed once production tenancy is live).
- **Repo:** private. License pending — do not redistribute.

---

*Volume 01 · v1.0 · Live, governed.*
