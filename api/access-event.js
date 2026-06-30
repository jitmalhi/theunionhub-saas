/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub Access · api/access-event.js
   Server-side Access Event recorder for the public representative page.

   The representative profile page (tenants/_template/access.html) POSTs here
   once on load. This route logs one Access Event into the analytics table
   using the SERVICE-ROLE key — which bypasses RLS — because migration 0013
   deliberately gives that table NO anon/authenticated INSERT policy. This
   route is therefore the ONLY write path: a forged Access Event would need
   the secret service-role key, which never leaves the server.

   API contract  (network vocabulary):
     POST /api/access-event
     body: { "representative_id": "<uuid>", "device_type"?: "mobile|tablet|desktop" }
     → 204 on success (no body)
     → 400 invalid_representative_id | 404 representative_not_found
     → 403 wrong_tenant | 405 method_not_allowed
     → 500 server_misconfigured | 502 insert_failed

   ⚠ Schema mapping: the public field is `representative_id`, but the live
   database column (migration 0013) is `steward_id`. We map representative_id
   → steward_id at the insert boundary. If/when the schema is renamed to the
   network vocabulary (representatives / access_events / representative_id),
   drop the mapping and use the column directly.

   Defense in depth (service_role bypasses RLS, so we validate ourselves):
     1. representative_id must be a well-formed uuid.
     2. the representative must exist.
     3. if the request host resolves to a tenant, the representative must
        belong to it (blocks logging an event for another union's rep).

   Env (server-only — never shipped to the browser):
     SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  (required)
     SUPABASE_ANON_KEY, PUBLIC_BASE_DOMAIN     (optional; tenant match)
   ────────────────────────────────────────────────────────────────────────── */

import { RESERVED_SLUGS } from '../lib/reserved-slugs.js';
import { serverConfigForHost } from '../lib/domains.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ALLOWED_DEVICE = new Set(['mobile', 'tablet', 'desktop', 'unknown']);

/* RESERVED_SLUGS is imported from ../lib/reserved-slugs.js (single source,
   shared with the middleware and lib/tenant.js). */

function deviceFromUA(ua) {
  ua = String(ua || '').toLowerCase();
  if (!ua) return 'unknown';
  /* Tablet first: an Android tablet has no "mobile" token; newer iPadOS
     reports a desktop-class UA we accept as desktop by design. */
  if (/ipad|tablet|playbook|silk|kindle|(android(?!.*mobile))/.test(ua)) return 'tablet';
  if (/mobi|iphone|ipod|android.*mobile|windows phone|iemobile/.test(ua)) return 'mobile';
  return 'desktop';
}

function slugFromHost(host, apexEnv) {
  const apex = String(apexEnv || 'theunionhub.com').toLowerCase();
  const bare = String(host || '').split(':')[0].toLowerCase();
  if (!bare || bare === apex) return null;

  let slug = null;
  if (bare.endsWith('.' + apex)) {
    slug = bare.slice(0, -(apex.length + 1));
  } else {
    /* dev / preview fallback (lvh.me, *.vercel.app): first label */
    const parts = bare.split('.');
    if (parts.length >= 2) slug = parts[0];
  }
  if (!slug || RESERVED_SLUGS.has(slug)) return null;
  return slug.includes('.') ? null : slug;
}

async function readJsonBody(req) {
  if (req.body && typeof req.body === 'object') return req.body;
  if (typeof req.body === 'string') {
    try { return JSON.parse(req.body); } catch { return {}; }
  }
  try {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'method_not_allowed' });
  }

  const env = process.env;
  /* Region-aware: resolve this host's Supabase project (US for
     theunionhub.com, CA for theunionhub.ca). For the DEFAULT region the legacy
     unsuffixed env vars (SUPABASE_URL / _ANON_KEY / _SERVICE_ROLE_KEY) are
     honoured, so .com behaviour is unchanged; .ca uses its suffixed vars. */
  const cfg = serverConfigForHost(req.headers.host, env);
  const SUPABASE_URL = String(cfg.supabaseUrl || '').replace(/\/+$/, '');
  const SERVICE_KEY  = cfg.serviceRoleKey;
  const ANON_KEY     = cfg.anonKey;

  if (!SUPABASE_URL || !SERVICE_KEY) {
    return res.status(500).json({ error: 'server_misconfigured' });
  }

  const svc = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` };

  const body = await readJsonBody(req);
  /* Accept the network field name; fall back to the legacy column name so a
     stale client can't silently no-op during the rename window. */
  const repId = (body && (body.representative_id || body.steward_id)) || null;

  if (!repId || !UUID_RE.test(String(repId))) {
    return res.status(400).json({ error: 'invalid_representative_id' });
  }

  const hinted = body && typeof body.device_type === 'string'
    ? body.device_type.toLowerCase()
    : null;
  const device = ALLOWED_DEVICE.has(hinted)
    ? hinted
    : deviceFromUA(req.headers['user-agent']);

  try {
    /* 2 · representative must exist (service_role read bypasses RLS).
       Table/column are still the live 0013 names (stewards / steward_id). */
    const sRes = await fetch(
      `${SUPABASE_URL}/rest/v1/stewards?id=eq.${encodeURIComponent(repId)}`
      + `&select=id,tenant_id&limit=1`,
      { headers: { ...svc, Accept: 'application/json' } }
    );
    if (!sRes.ok) return res.status(502).json({ error: 'lookup_failed' });
    const rows = await sRes.json();
    const rep = Array.isArray(rows) ? rows[0] : null;
    if (!rep) return res.status(404).json({ error: 'representative_not_found' });

    /* 3 · best-effort tenant match. */
    const slug = slugFromHost(req.headers.host, env.PUBLIC_BASE_DOMAIN || cfg.apex);
    if (slug && ANON_KEY) {
      const tRes = await fetch(
        `${SUPABASE_URL}/rest/v1/tenants?slug=eq.${encodeURIComponent(slug)}&select=id&limit=1`,
        { headers: { apikey: ANON_KEY, Authorization: `Bearer ${ANON_KEY}`, Accept: 'application/json' } }
      );
      if (tRes.ok) {
        const tRows = await tRes.json();
        const tenant = Array.isArray(tRows) ? tRows[0] : null;
        if (tenant && tenant.id && tenant.id !== rep.tenant_id) {
          return res.status(403).json({ error: 'wrong_tenant' });
        }
      }
    }

    /* 4 · log the Access Event. representative_id → steward_id (live column). */
    const ins = await fetch(`${SUPABASE_URL}/rest/v1/steward_analytics`, {
      method: 'POST',
      headers: { ...svc, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
      body: JSON.stringify({ steward_id: repId, device_type: device }),
    });

    if (!ins.ok) {
      const detail = await ins.text().catch(() => '');
      return res.status(502).json({ error: 'insert_failed', detail: detail.slice(0, 300) });
    }

    res.setHeader('Cache-Control', 'no-store');
    return res.status(204).end();
  } catch (e) {
    return res.status(502).json({ error: 'upstream_error' });
  }
}
