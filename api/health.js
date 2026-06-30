/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub Access · api/health.js
   A lightweight, non-sensitive readiness check. Reports whether this host's
   Supabase config is wired up — WITHOUT ever exposing a key.

   Region-aware: resolves config for the request host (theunionhub.com vs
   theunionhub.ca) via serverConfigForHost, so /api/health reflects the right
   region's setup.

   GET /api/health
     → 200 { ready: true,  … }   when URL + a real service-role key are present
     → 503 { ready: false, … }   otherwise (e.g. service-role key still a placeholder)
   ────────────────────────────────────────────────────────────────────────── */

import { serverConfigForHost } from '../lib/domains.js';

export default async function handler(req, res) {
  const env = process.env;
  const cfg = serverConfigForHost(req.headers.host, env);

  // Status only — never echo the key itself. The placeholder counts as "not set".
  const hasServiceKey  = !!cfg.serviceRoleKey && cfg.serviceRoleKey !== 'REPLACE_WITH_CLOUD_SERVICE_ROLE_KEY';
  const hasSupabaseUrl = !!cfg.supabaseUrl;

  const status = {
    ready: hasServiceKey && hasSupabaseUrl,
    components: {
      supabase_connection:     hasSupabaseUrl,
      service_role_configured: hasServiceKey,   // gates the service-role writers (DFR + scan logs)
      region:                  cfg.region,
      migration_version:       '0021',
    },
    timestamp: new Date().toISOString(),
  };

  res.setHeader('Cache-Control', 'no-store');
  res.status(status.ready ? 200 : 503).json(status);
}
