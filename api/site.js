/* ──────────────────────────────────────────────────────────────────────────
   api/site.js
   Server-side renderer endpoint for Tier-1 public union-local websites.

   The edge middleware routes {slug}.theunionhub.ca (and, in phase 3, custom
   domains) here. This function:
     1. resolves the incoming Host → tenant via resolve_site_tenant() (0036),
     2. if the site is published, pulls the whole site in ONE call via
        get_public_site() (0038),
     3. renders it with lib/site-render.js and returns HTML (no client fetch).

   All Tier-1 sites live on the ONE live Supabase project — resolution is by
   hostname, but the Supabase config is always the primary (.com) project, never
   the request host's region (a .ca host has no separate project).
   ────────────────────────────────────────────────────────────────────────── */

import { serverConfigForHost } from '../lib/domains.js';
import { renderSitePage } from '../lib/site-render.js';

const ESCAPE = { '&': '&amp;', '<': '&lt;', '>': '&gt;' };
const e = (s) => String(s == null ? '' : s).replace(/[&<>]/g, (c) => ESCAPE[c]);

function send(res, status, html, cache) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  res.setHeader('Cache-Control', cache);
  res.end(html);
}

function notFoundPage(host) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>Site not found</title><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#fbf9f4;color:#3d4149;
font-family:system-ui,-apple-system,sans-serif;text-align:center;padding:24px}
h1{font-size:26px;color:#23252b;margin:0 0 8px}p{margin:0;color:#6d6f78;max-width:44ch}
a{color:#274b6d}</style></head><body><div><h1>No site here yet</h1>
<p>There's no published union-local site at <strong>${e(host)}</strong>. If you're the local's admin, publish your site from your Union Hub dashboard.</p>
<p style="margin-top:18px"><a href="https://theunionhub.ca">Union Hub</a></p></div></body></html>`;
}

// Per-site robots.txt: index a published site; keep an unpublished/unknown host
// out of search results.
function robotsTxt(res, host, hit) {
  const published = hit && hit.published;
  const body = published
    ? `User-agent: *\nAllow: /\nSitemap: https://${host}/sitemap.xml\n`
    : `User-agent: *\nDisallow: /\n`;
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Cache-Control', 'public, s-maxage=300, stale-while-revalidate=600');
  res.end(body);
}

// Per-site sitemap: one URL for the one-page site, lastmod from the site's
// settings.updated_at (carried by resolve_site_tenant).
function sitemapXml(res, host, hit) {
  const head = '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">';
  if (!hit || !hit.published) {
    res.statusCode = 200;
    res.setHeader('Content-Type', 'application/xml; charset=utf-8');
    res.setHeader('Cache-Control', 'public, s-maxage=60');
    return res.end(`${head}\n</urlset>\n`);
  }
  const lastmod = hit.updated_at ? String(hit.updated_at).slice(0, 10) : '';
  res.statusCode = 200;
  res.setHeader('Content-Type', 'application/xml; charset=utf-8');
  res.setHeader('Cache-Control', 'public, s-maxage=300, stale-while-revalidate=600');
  res.end(`${head}\n  <url><loc>https://${e(host)}/</loc>${lastmod ? `<lastmod>${lastmod}</lastmod>` : ''}<changefreq>weekly</changefreq></url>\n</urlset>\n`);
}

export default async function handler(req, res) {
  const host = String(req.headers['x-site-host'] || req.headers.host || '')
    .split(':')[0].toLowerCase().trim();

  // The one live Supabase project (primary apex), independent of the .ca host.
  const cfg = serverConfigForHost('theunionhub.com', process.env);
  const url = cfg.supabaseUrl, anonKey = cfg.anonKey;
  if (!url || !anonKey) return send(res, 503, notFoundPage(host), 'no-store');

  const rpc = (fn, body) => fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: anonKey, Authorization: `Bearer ${anonKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });

  try {
    // 1 · hostname → tenant
    const r1 = await rpc('resolve_site_tenant', { p_hostname: host });
    const rows = r1.ok ? await r1.json() : [];
    const hit = Array.isArray(rows) ? rows[0] : rows;

    // Per-site SEO files (routed here by the middleware for .ca website hosts).
    const sitePath = String(req.headers['x-site-path'] || '/');
    if (sitePath === '/robots.txt')  return robotsTxt(res, host, hit);
    if (sitePath === '/sitemap.xml') return sitemapXml(res, host, hit);

    // Unknown host, or resolved but not published → 404 (short cache so a fresh
    // publish goes live quickly).
    if (!hit || !hit.tenant_id || !hit.published) {
      return send(res, 404, notFoundPage(host), 'public, s-maxage=30, stale-while-revalidate=60');
    }

    // 2 · whole published site in one call
    const r2 = await rpc('get_public_site', { p_tenant_id: hit.tenant_id });
    const site = r2.ok ? await r2.json() : null;
    if (!site) return send(res, 404, notFoundPage(host), 'public, s-maxage=30');

    // 3 · render
    return send(res, 200, renderSitePage(site),
      'public, s-maxage=120, stale-while-revalidate=600');
  } catch (err) {
    console.error('[uh/site] render failed:', err && err.message ? err.message : err);
    return send(res, 500, notFoundPage(host), 'no-store');
  }
}
