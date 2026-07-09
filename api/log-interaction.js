/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub Access · api/log-interaction.js
   Server-side recorder for the member↔steward representation log (DFR defense).

   The Member View (tenants/_template/access/meet.html) POSTs here when a member
   confirms a representation meeting. This route writes ONE row into
   public.member_interactions using the SERVICE-ROLE key — which bypasses RLS —
   because migration 0020 gives that table NO anon/authenticated INSERT policy.
   This route is the only DB-WRITE path (the table has no anon/authenticated
   INSERT policy, so a direct client insert is impossible). Be precise about what
   that buys, though: the ENDPOINT itself is anonymously callable and only
   validates that steward_id exists — it does not authenticate the member. So a
   row proves "someone POSTed this steward_id through this route," not the
   member's identity, and there is no rate limiting. Treat it as an attributable
   log, not a cryptographically un-forgeable one. Hardening (auth, provenance,
   rate limiting) is tracked in docs/BACKLOG.md (Fable review #4).

   API contract:
     POST /api/log-interaction
     body: {
       "steward_id": "<uuid>",            (required)
       "confirmed": true|false,
       "topic": "Grievance" | "Health & Safety" | "General Inquiry"
              | "Discipline" | "Scheduling" | "Other" | null,
       "understood_next_steps": true|false,
       "device_type"?: "mobile|tablet|desktop"
     }
     → 201 { ok: true }
     → 400 invalid_steward_id | 404 steward_not_found | 403 wrong_tenant
     → 405 method_not_allowed | 500 server_misconfigured | 502 insert_failed

   Region-aware: resolves the Supabase project for the request host
   (theunionhub.com vs theunionhub.ca) via serverConfigForHost.
   ────────────────────────────────────────────────────────────────────────── */

import { RESERVED_SLUGS } from '../lib/reserved-slugs.js';
import { serverConfigForHost } from '../lib/domains.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ALLOWED_DEVICE = new Set(['mobile', 'tablet', 'desktop', 'unknown']);
const ALLOWED_TOPIC = new Set([
  'Grievance', 'Health & Safety', 'General Inquiry', 'Discipline', 'Scheduling', 'Other',
]);

function deviceFromUA(ua) {
  ua = String(ua || '').toLowerCase();
  if (!ua) return 'unknown';
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
    const parts = bare.split('.');
    if (parts.length >= 2) slug = parts[0];
  }
  if (!slug || RESERVED_SLUGS.has(slug)) return null;
  return slug.includes('.') ? null : slug;
}

async function readJsonBody(req) {
  if (req.body && typeof req.body === 'object') return req.body;
  if (typeof req.body === 'string') { try { return JSON.parse(req.body); } catch { return {}; } }
  try {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    return raw ? JSON.parse(raw) : {};
  } catch { return {}; }
}

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'method_not_allowed' });
  }

  const env = process.env;
  const cfg = serverConfigForHost(req.headers.host, env);
  const SUPABASE_URL = String(cfg.supabaseUrl || '').replace(/\/+$/, '');
  const SERVICE_KEY  = cfg.serviceRoleKey;
  const ANON_KEY     = cfg.anonKey;

  if (!SUPABASE_URL || !SERVICE_KEY) {
    return res.status(500).json({ error: 'server_misconfigured' });
  }
  const svc = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` };

  const body = await readJsonBody(req);
  const stewardId = (body && body.steward_id) || null;
  if (!stewardId || !UUID_RE.test(String(stewardId))) {
    return res.status(400).json({ error: 'invalid_steward_id' });
  }

  const confirmed = body.confirmed === true || body.confirmed === 'true';
  const understood = body.understood_next_steps === true || body.understood_next_steps === 'true';
  const topic = (body.topic && ALLOWED_TOPIC.has(body.topic)) ? body.topic : null;
  const hinted = body && typeof body.device_type === 'string' ? body.device_type.toLowerCase() : null;
  const device = ALLOWED_DEVICE.has(hinted) ? hinted : deviceFromUA(req.headers['user-agent']);

  try {
    // 1 · The steward must exist (service_role read bypasses RLS). Get its tenant.
    const sRes = await fetch(
      `${SUPABASE_URL}/rest/v1/stewards?id=eq.${encodeURIComponent(stewardId)}&select=id,tenant_id&limit=1`,
      { headers: { ...svc, Accept: 'application/json' } }
    );
    if (!sRes.ok) return res.status(502).json({ error: 'lookup_failed' });
    const rows = await sRes.json();
    const steward = Array.isArray(rows) ? rows[0] : null;
    if (!steward) return res.status(404).json({ error: 'steward_not_found' });

    // 2 · Best-effort tenant match — block logging against another union's steward.
    const slug = slugFromHost(req.headers.host, env.PUBLIC_BASE_DOMAIN || cfg.apex);
    if (slug && ANON_KEY) {
      const tRes = await fetch(
        `${SUPABASE_URL}/rest/v1/tenants?slug=eq.${encodeURIComponent(slug)}&select=id&limit=1`,
        { headers: { apikey: ANON_KEY, Authorization: `Bearer ${ANON_KEY}`, Accept: 'application/json' } }
      );
      if (tRes.ok) {
        const tRows = await tRes.json();
        const tenant = Array.isArray(tRows) ? tRows[0] : null;
        if (tenant && tenant.id && tenant.id !== steward.tenant_id) {
          return res.status(403).json({ error: 'wrong_tenant' });
        }
      }
    }

    // 3 · Write the DFR record.
    const ins = await fetch(`${SUPABASE_URL}/rest/v1/member_interactions`, {
      method: 'POST',
      headers: { ...svc, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
      body: JSON.stringify({
        tenant_id: steward.tenant_id,
        steward_id: stewardId,
        confirmed,
        topic,
        understood_next_steps: understood,
        device_type: device,
      }),
    });
    if (!ins.ok) {
      const detail = await ins.text().catch(() => '');
      return res.status(502).json({ error: 'insert_failed', detail: detail.slice(0, 300) });
    }

    res.setHeader('Cache-Control', 'no-store');
    return res.status(201).json({ ok: true });
  } catch (e) {
    return res.status(502).json({ error: 'upstream_error' });
  }
}
