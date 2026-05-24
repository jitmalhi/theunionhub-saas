# tenants/

Tenant-scoped application surfaces. Every union — `local183`, `local419`,
`local52`, etc. — is served out of this single directory by the edge
middleware in [api/_middleware.js](../api/_middleware.js).

There is no per-tenant deploy, no per-tenant build artefact, and no
per-tenant code. A new union becomes live the moment two things are true:

1. A row exists in `public.tenants` with `slug = <name>` and `status = 'active'`.
2. DNS for `<name>.theunionhub.com` resolves to `cname.vercel-dns.com`.

---

## Layout

```
tenants/
├── README.md             ← you are here
└── _template/            ← reference layout — NEVER deployed as a tenant
    ├── card.html         ← /card  (member digital card)
    ├── verify.html       ← /verify (public verification page)
    └── tenant.css        ← per-tenant accent / logo overrides
```

`_template/` is the canonical implementation. Every tenant renders these
exact files; the differences are injected at request time:

| Slot                       | Source                                | Mechanism                          |
| -------------------------- | ------------------------------------- | ---------------------------------- |
| `--accent-tenant`          | `tenants.accent_hex` (Supabase)       | Inline `<style>` by template       |
| `[data-tenant-logo]`       | `tenant-assets` Storage bucket        | `<img>` / `<svg>` by template      |
| `[data-tenant-name]`       | `tenants.display_name`                | `textContent` by template          |
| Member data                | `members WHERE tenant_id = …`         | `/api/tenants/[slug]/members`      |
| Verification result        | `verifications` table + RLS           | `/api/tenants/[slug]/verify/[id]`  |

---

## Provisioning a new tenant

```bash
npm run new-tenant -- \
  --slug local52 \
  --name "IBEW Local 52" \
  --accent "#0F6E56" \
  --contact admin@local52.org
```

The script performs, in order:

1. **Validate slug** — must match `^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$`,
   must not be in the reserved list (see `api/_middleware.js` for the
   canonical set), and must not collide with an existing row.
2. **Validate accent** — contrast against `--off-white` (#F5F4F1) must
   pass WCAG AA for body text (≥ 4.5:1). Rejects with a remediation hint.
3. **Insert tenants row** with `status = 'pending'`.
4. **DNS check** — resolves `<slug>.theunionhub.com`, retries with
   exponential backoff up to 5 minutes. Fails loud if the CNAME is wrong.
5. **Issue magic-link** to `--contact` for first admin sign-in.
6. **Seed audit_log** with row 0 (`tenant_created`, actor = system).
7. **Flip status to 'active'** once DNS is verified.

The same script run with `--dry-run` prints what would happen without
mutating the database or sending email.

---

## Reserved slugs

These are blocked by both a CHECK constraint on `tenants.slug` and the
in-memory set in [api/_middleware.js](../api/_middleware.js):

`www`, `app`, `api`, `admin`, `status`, `docs`, `blog`, `mail`, `assets`,
`cdn`, `static`, `demo-www`

Add new reservations in **both places** in the same commit, or routing
diverges from the database.

---

## What a tenant cannot do

Per the brand book (Volume 01) and locked by `css/tokens.css`:

- Change typography (Playfair Display / DM Sans / DM Mono).
- Change layout (grid, page padding, max widths).
- Change motion (durations, easings, `uhpulse`).
- Change hairlines, radii, or the no-shadow / no-gradient rules.
- Change the card or verify component structure (HTML is shared).

A tenant gets a logo, a display name, and one accent colour. That is the
entire surface area. If a union needs more, that's a brand book
amendment, not a per-tenant override.

---

## Testing a tenant locally

`lvh.me` resolves all subdomains to `127.0.0.1`. With `vercel dev` running:

```
http://demo.lvh.me:3000/          → tenants/_template/card.html (slug=demo)
http://demo.lvh.me:3000/card?id=… → same, with a specific member
http://demo.lvh.me:3000/verify?id=… → tenants/_template/verify.html
http://local183.lvh.me:3000/      → same template, slug=local183
```

The middleware does not validate that `local183` exists in the database
when running locally — that check belongs to the page-level fetch so the
404 path can render a consistent "tenant not found" template instead of
a generic edge error.
