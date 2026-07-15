/* ──────────────────────────────────────────────────────────────────────────
   api/site-export.js
   Content export for Tier-1 sites — "your content is yours."

   Authenticated tenant admins download their ENTIRE site as JSON (settings +
   all content incl drafts + hostnames + a files manifest). This endpoint is a
   thin pass-through: it forwards the admin's magic-link JWT + x-tenant-id to the
   export_site() RPC (0039), which does the admin check and gathers everything.
   No service-role key here — authorization is the RPC's job, over the user's
   own token. Called from the authenticated admin app.
   ────────────────────────────────────────────────────────────────────────── */

import { serverConfigForHost } from '../lib/domains.js';

function json(res, status, obj, extraHeaders) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  if (extraHeaders) for (const [k, v] of Object.entries(extraHeaders)) res.setHeader(k, v);
  res.end(typeof obj === 'string' ? obj : JSON.stringify(obj));
}

export default async function handler(req, res) {
  const auth     = req.headers['authorization'];
  const tenantId = req.headers['x-tenant-id'];
  if (!auth || !tenantId) {
    return json(res, 401, { error: 'auth_required',
      detail: 'Send Authorization: Bearer <session token> and x-tenant-id.' });
  }

  const cfg = serverConfigForHost(req.headers.host || 'theunionhub.ca', process.env);
  const url = cfg.supabaseUrl, anonKey = cfg.anonKey;
  if (!url || !anonKey) return json(res, 503, { error: 'backend_unconfigured' });

  try {
    const r = await fetch(`${url}/rest/v1/rpc/export_site`, {
      method: 'POST',
      headers: {
        apikey: anonKey,
        Authorization: auth,             // the admin's own JWT (auth.uid())
        'x-tenant-id': tenantId,         // selects the tenant; RPC authorizes it
        'Content-Type': 'application/json',
      },
      body: '{}',
    });

    if (!r.ok) {
      const body = await r.text().catch(() => '');
      // 401/403 from the RPC → not an admin of this tenant.
      const status = (r.status === 401 || r.status === 403) ? 403 : 502;
      return json(res, status, { error: 'export_failed', status: r.status, detail: body.slice(0, 300) });
    }

    const data = await r.json();
    const slug = (data && data.tenant && data.tenant.slug) ? data.tenant.slug : 'site';
    return json(res, 200, JSON.stringify(data, null, 2), {
      'Content-Disposition': `attachment; filename="${slug}-site-export.json"`,
    });
  } catch (err) {
    console.error('[uh/site-export] failed:', err && err.message ? err.message : err);
    return json(res, 502, { error: 'export_failed' });
  }
}
