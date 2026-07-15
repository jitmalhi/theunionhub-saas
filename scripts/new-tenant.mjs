#!/usr/bin/env node
/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · scripts/new-tenant.mjs
   Provision a new union tenant: validate, insert, verify DNS, send invite.

   The repeatable, automation-friendly way to onboard a new local. Mirrors
   the recipe documented in tenants/README.md. The single command that
   keeps middleware, database, DNS, and email in lockstep.

   Usage:
     npm run new-tenant -- --slug <slug> --name "<display>" --contact <email> [options]

   Required:
     --slug <slug>             URL label. ^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$
     --name "<display>"        Human-readable name on the card / verify page.
     --contact <email>         Primary admin; receives the magic-link.

   Optional:
     --accent <#RRGGBB>        Per-tenant accent. Default #0F6E56 (brand).
                               Validated for WCAG AA vs #F5F4F1 (≥ 4.5:1).
     --local <number>          Union local number ("183", "B-9", etc.). Text.
     --union-type <type>       Parent org (IBEW, UA, LIUNA, …). Free text.
     --apex <domain>           Override PUBLIC_BASE_DOMAIN env. Default theunionhub.ca.

     --skip-dns                Don't wait for DNS to propagate. Status stays
                               'pending' and you flip it manually later.
     --skip-magic-link         Don't email the admin. Tenant is created
                               'pending'; flip status manually if no email
                               is desired.
     --dry-run                 Validate inputs and print the plan; mutate nothing.
     --help                    This text.

   Environment:
     SUPABASE_URL                  required
     SUPABASE_SERVICE_ROLE_KEY     required for tenant INSERT (bypasses RLS)
     SUPABASE_ANON_KEY             required for magic-link request
     PUBLIC_BASE_DOMAIN            optional; defaults to 'theunionhub.ca'

     The script auto-loads .env.local from the project root if it exists.
     Process env wins over .env.local.

   Exit codes:
     0  full success
     1  validation / usage error (fix args and retry)
     2  infrastructure failure (database, DNS, mail — retry later)
     3  partial success (tenant created, downstream step failed — resume needed)

   What it does NOT do (deliberately):
     · Create members. Members are added via the admin app or CSV import.
     · Upload a logo. Logos go to the tenant-assets Storage bucket separately.
     · Wire DNS. DNS must be configured ahead of time (CNAME wildcard or
       per-slug record). The script verifies, doesn't create.

   Security notes:
     · SUPABASE_SERVICE_ROLE_KEY bypasses RLS — it is the master key for
       this project. Never log it, never include it in error messages,
       never commit a .env file containing it.
     · This script never prints the service role key. The Supabase
       fetch helpers below mask it from any error path that bubbles up.
   ────────────────────────────────────────────────────────────────────────── */

import { parseArgs } from 'node:util';
import { resolveCname, resolve4 } from 'node:dns/promises';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve as resolvePath } from 'node:path';
import process from 'node:process';

/* ════════════════════════════════════════════════════════════════════════
   0 · CONSTANTS — mirror the middleware + the database CHECK constraint
   ════════════════════════════════════════════════════════════════════════ */

const SLUG_REGEX = /^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$/;

const RESERVED_SLUGS = new Set([
  'www', 'app', 'api', 'admin', 'status', 'docs', 'blog',
  'mail', 'assets', 'cdn', 'static', 'demo-www',
]);

const DEFAULT_ACCENT = '#0F6E56';
const OFF_WHITE      = '#F5F4F1';
const WCAG_AA_MIN    = 4.5;

const VERCEL_CNAME_TARGET = 'cname.vercel-dns.com';

const DNS_BACKOFF_MS_INITIAL = 10_000;
const DNS_BACKOFF_MS_MAX     = 60_000;
const DNS_TOTAL_BUDGET_MS    = 5 * 60_000;

const EXIT = {
  OK:              0,
  USAGE:           1,
  INFRA:           2,
  PARTIAL_SUCCESS: 3,
};


/* ════════════════════════════════════════════════════════════════════════
   1 · TERMINAL OUTPUT — colour, only if the terminal supports it
   ════════════════════════════════════════════════════════════════════════ */

const useColor = process.stdout.isTTY && process.env.NO_COLOR !== '1';
const c = useColor
  ? {
      dim:    (s) => `\x1b[2m${s}\x1b[0m`,
      bold:   (s) => `\x1b[1m${s}\x1b[0m`,
      green:  (s) => `\x1b[32m${s}\x1b[0m`,
      red:    (s) => `\x1b[31m${s}\x1b[0m`,
      yellow: (s) => `\x1b[33m${s}\x1b[0m`,
      cyan:   (s) => `\x1b[36m${s}\x1b[0m`,
    }
  : { dim: (s) => s, bold: (s) => s, green: (s) => s, red: (s) => s, yellow: (s) => s, cyan: (s) => s };

const log = {
  banner: (msg) => console.log(c.bold('\nThe Union Hub · ') + c.dim(msg) + '\n'),
  plan:   (msg) => console.log(c.cyan('▶ ') + msg),
  step:   (msg) => process.stdout.write(c.dim('→ ') + msg + ' ... '),
  ok:     (msg) => console.log(c.green('ok' + (msg ? '  ' + c.dim(msg) : ''))),
  skip:   (msg) => console.log(c.yellow('skipped' + (msg ? '  ' + c.dim(msg) : ''))),
  fail:   (msg) => console.log(c.red('FAIL' + (msg ? '  ' + msg : ''))),
  info:   (msg) => console.log(c.dim('  ' + msg)),
  ok_line:   (label, val) => console.log(`  ${c.dim(label.padEnd(14))} ${val}`),
  warn:   (msg) => console.warn(c.yellow('⚠ ') + msg),
  error:  (msg) => console.error(c.red('✗ ') + msg),
};


/* ════════════════════════════════════════════════════════════════════════
   2 · ENV LOADING — .env.local if present, process.env always wins
   ════════════════════════════════════════════════════════════════════════ */

const PROJECT_ROOT = resolvePath(dirname(fileURLToPath(import.meta.url)), '..');

async function loadDotEnvLocal() {
  const path = resolvePath(PROJECT_ROOT, '.env.local');
  try {
    const text = await readFile(path, 'utf8');
    for (const raw of text.split('\n')) {
      const line = raw.trim();
      if (!line || line.startsWith('#')) continue;
      const eq = line.indexOf('=');
      if (eq < 0) continue;
      const key = line.slice(0, eq).trim();
      let val   = line.slice(eq + 1).trim();
      if ((val.startsWith('"') && val.endsWith('"')) ||
          (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1);
      }
      // process.env wins over file — explicit overrides are sacred.
      if (!(key in process.env)) process.env[key] = val;
    }
  } catch (e) {
    if (e.code !== 'ENOENT') throw e;
  }
}


/* ════════════════════════════════════════════════════════════════════════
   3 · WCAG CONTRAST — accent vs --off-white
   ════════════════════════════════════════════════════════════════════════ */

function hexToRgb(hex) {
  const m = hex.match(/^#([0-9a-fA-F]{6})$/);
  if (!m) throw new Error(`Invalid hex colour: ${hex}`);
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
}

function relativeLuminance([r, g, b]) {
  const norm = (v) => {
    const s = v / 255;
    return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * norm(r) + 0.7152 * norm(g) + 0.0722 * norm(b);
}

function contrastRatio(hexA, hexB) {
  const la = relativeLuminance(hexToRgb(hexA));
  const lb = relativeLuminance(hexToRgb(hexB));
  const lighter = Math.max(la, lb);
  const darker  = Math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}


/* ════════════════════════════════════════════════════════════════════════
   4 · ARG PARSING + VALIDATION
   ════════════════════════════════════════════════════════════════════════ */

function parseArgsOrDie(argv) {
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      options: {
        slug:              { type: 'string' },
        name:              { type: 'string' },
        contact:           { type: 'string' },
        accent:            { type: 'string', default: DEFAULT_ACCENT },
        local:             { type: 'string' },
        'union-type':      { type: 'string' },
        apex:              { type: 'string' },
        'skip-dns':        { type: 'boolean', default: false },
        'skip-magic-link': { type: 'boolean', default: false },
        'dry-run':         { type: 'boolean', default: false },
        help:              { type: 'boolean', short: 'h', default: false },
      },
      strict: true,
      allowPositionals: false,
    });
  } catch (e) {
    log.error(`Argument parse error: ${e.message}`);
    printUsage();
    process.exit(EXIT.USAGE);
  }
  return parsed.values;
}

function printUsage() {
  console.log(`
Usage:
  npm run new-tenant -- --slug <slug> --name "<display>" --contact <email> [options]

Required:
  --slug <slug>             URL label (^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$)
  --name "<display>"        Human-readable name on the card / verify page
  --contact <email>         Primary admin; receives the magic-link

Optional:
  --accent <#RRGGBB>        Per-tenant accent (default ${DEFAULT_ACCENT}). WCAG AA validated.
  --local <number>          Union local number (text — "183", "B-9", …)
  --union-type <type>       Parent org ("IBEW", "UA", "LIUNA", …)
  --apex <domain>           Override PUBLIC_BASE_DOMAIN. Default theunionhub.ca.
  --skip-dns                Don't wait for DNS; tenant stays 'pending'
  --skip-magic-link         Don't email the admin
  --dry-run                 Validate + print plan; mutate nothing
  --help                    This text
`);
}

function validateOrDie(args) {
  const errors = [];

  // Required
  if (!args.slug)    errors.push('--slug is required');
  if (!args.name)    errors.push('--name is required');
  if (!args.contact) errors.push('--contact is required');

  // Slug shape
  if (args.slug) {
    if (!SLUG_REGEX.test(args.slug)) {
      errors.push(`--slug "${args.slug}" must match ${SLUG_REGEX} (2–32 lowercase alnum or hyphen, no leading/trailing hyphen)`);
    }
    if (RESERVED_SLUGS.has(args.slug)) {
      errors.push(`--slug "${args.slug}" is reserved. Reserved: ${[...RESERVED_SLUGS].join(', ')}`);
    }
  }

  // Display name
  if (args.name && args.name.trim().length === 0) {
    errors.push('--name must not be blank');
  }

  // Contact email — same loose CHECK as the migration
  if (args.contact && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(args.contact)) {
    errors.push(`--contact "${args.contact}" doesn't look like an email`);
  }

  // Accent
  let contrast = null;
  if (args.accent) {
    if (!/^#[0-9a-fA-F]{6}$/.test(args.accent)) {
      errors.push(`--accent "${args.accent}" must be #RRGGBB hex`);
    } else {
      try {
        contrast = contrastRatio(args.accent, OFF_WHITE);
        if (contrast < WCAG_AA_MIN) {
          errors.push(
            `--accent ${args.accent} fails WCAG AA contrast vs ${OFF_WHITE} ` +
            `(ratio ${contrast.toFixed(2)}:1, minimum ${WCAG_AA_MIN}:1). ` +
            `Pick a darker accent.`
          );
        }
      } catch (e) {
        errors.push(e.message);
      }
    }
  }

  // Env
  if (!process.env.SUPABASE_URL) {
    errors.push('SUPABASE_URL env var is required (set in .env.local)');
  }
  if (!process.env.SUPABASE_SERVICE_ROLE_KEY) {
    errors.push('SUPABASE_SERVICE_ROLE_KEY env var is required (set in .env.local)');
  }
  if (!process.env.SUPABASE_ANON_KEY && !args['skip-magic-link']) {
    errors.push('SUPABASE_ANON_KEY env var is required for magic-link (or pass --skip-magic-link)');
  }

  if (errors.length) {
    log.error('Validation failed:');
    for (const err of errors) console.error('   · ' + err);
    process.exit(EXIT.USAGE);
  }

  return { contrast };
}


/* ════════════════════════════════════════════════════════════════════════
   5 · SUPABASE REST — service role + anon, both with key masking
   ════════════════════════════════════════════════════════════════════════ */

const SUPABASE_URL = () => process.env.SUPABASE_URL.replace(/\/+$/, '');

/**
 * Strips the secret out of any thrown error message. Defence in depth in
 * case a response body echoes back the auth header (PostgREST normally
 * doesn't, but we don't trust normally).
 */
function maskKey(s, key) {
  if (!key || !s) return s;
  return String(s).split(key).join('<REDACTED-KEY>');
}

async function sbFetch(path, init = {}) {
  const isServiceRole = init._serviceRole === true;
  const key = isServiceRole
    ? process.env.SUPABASE_SERVICE_ROLE_KEY
    : process.env.SUPABASE_ANON_KEY;

  const headers = Object.assign(
    {
      apikey: key,
      Authorization: 'Bearer ' + key,
      'Content-Type': 'application/json',
    },
    init.headers || {}
  );

  const url = path.startsWith('http') ? path : SUPABASE_URL() + path;
  const opts = Object.assign({}, init, { headers });
  delete opts._serviceRole;

  let res;
  try {
    res = await fetch(url, opts);
  } catch (e) {
    throw new Error(`Network error calling ${url}: ${maskKey(e.message, key)}`);
  }

  return { res, key };
}

async function sbInsertTenant(row) {
  const { res, key } = await sbFetch('/rest/v1/tenants', {
    _serviceRole: true,
    method: 'POST',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify(row),
  });
  if (!res.ok) {
    const body = maskKey(await res.text(), key);
    if (res.status === 409 || /duplicate key|unique/i.test(body)) {
      throw new Error(`Tenant slug "${row.slug}" already exists`);
    }
    throw new Error(`INSERT failed (${res.status}): ${body}`);
  }
  const rows = await res.json();
  return rows[0];
}

async function sbActivateTenant(id) {
  const { res, key } = await sbFetch(`/rest/v1/tenants?id=eq.${encodeURIComponent(id)}`, {
    _serviceRole: true,
    method: 'PATCH',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify({ status: 'active' }),
  });
  if (!res.ok) {
    throw new Error(`UPDATE status=active failed (${res.status}): ${maskKey(await res.text(), key)}`);
  }
  const rows = await res.json();
  return rows[0];
}

async function sbSeedAuditRow(tenantId, slug) {
  // The audit_log table doesn't exist until migration 0004. We try the
  // insert; if it 404s (PostgREST) or fires a 42P01 (Postgres), we skip
  // gracefully. Any other error surfaces.
  const { res, key } = await sbFetch('/rest/v1/audit_log', {
    _serviceRole: true,
    method: 'POST',
    headers: { Prefer: 'return=minimal' },
    body: JSON.stringify({
      tenant_id: tenantId,
      action: 'tenant_created',
      actor: 'system:new-tenant.mjs',
      detail: { slug, source: 'provisioning_script' },
    }),
  });
  if (res.status === 404) return { skipped: 'table_missing' };
  if (!res.ok) {
    const body = maskKey(await res.text(), key);
    if (/relation .* does not exist|42P01/i.test(body)) {
      return { skipped: 'table_missing' };
    }
    throw new Error(`audit_log insert failed (${res.status}): ${body}`);
  }
  return { inserted: true };
}

async function sbSendMagicLink(email, redirectTo) {
  const { res, key } = await sbFetch('/auth/v1/otp', {
    method: 'POST',
    body: JSON.stringify({
      email,
      create_user: true,
      email_redirect_to: redirectTo,
    }),
  });
  if (!res.ok) {
    throw new Error(`Magic-link send failed (${res.status}): ${maskKey(await res.text(), key)}`);
  }
  return true;
}


/* ════════════════════════════════════════════════════════════════════════
   6 · DNS VERIFICATION — exponential backoff, max 5 minutes
   ════════════════════════════════════════════════════════════════════════ */

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function cnameTargets(hostname) {
  try {
    return await resolveCname(hostname);
  } catch (e) {
    if (e.code === 'ENOTFOUND' || e.code === 'ENODATA') return [];
    // Other DNS errors (e.g. NXDOMAIN bubbled differently): treat as not-yet-resolved
    return [];
  }
}

async function hostResolves(hostname) {
  try {
    const addrs = await resolve4(hostname);
    return addrs.length > 0;
  } catch {
    return false;
  }
}

/**
 * Wait until the slug's CNAME points to Vercel, OR the apex points to a
 * Vercel A record (wildcard CNAMEs sometimes don't chain through depending
 * on the DNS provider). Either constitutes a valid Vercel deployment.
 */
async function waitForDns(hostname) {
  const start = Date.now();
  let delay = DNS_BACKOFF_MS_INITIAL;
  let attempt = 0;

  while (Date.now() - start < DNS_TOTAL_BUDGET_MS) {
    attempt += 1;
    const elapsed = Math.round((Date.now() - start) / 1000);
    process.stdout.write(c.dim(`\n    attempt ${attempt} (t+${elapsed}s) ... `));

    const cnames = await cnameTargets(hostname);
    const matchingCname = cnames.find((t) => t.toLowerCase().includes('vercel'));
    if (matchingCname) {
      console.log(c.green(`✓ CNAME → ${matchingCname}`));
      return { ok: true, attempts: attempt, evidence: { cname: matchingCname } };
    }

    if (await hostResolves(hostname)) {
      console.log(c.green('✓ resolves (A record present; CNAME may be flattened)'));
      return { ok: true, attempts: attempt, evidence: { a_record: true } };
    }

    process.stdout.write(c.dim('not yet'));
    await sleep(delay);
    delay = Math.min(delay * 2, DNS_BACKOFF_MS_MAX);
  }

  console.log();
  return { ok: false, attempts: attempt };
}


/* ════════════════════════════════════════════════════════════════════════
   7 · ORCHESTRATION
   ════════════════════════════════════════════════════════════════════════ */

async function main() {
  await loadDotEnvLocal();

  const args = parseArgsOrDie(process.argv.slice(2));
  if (args.help) { printUsage(); process.exit(EXIT.OK); }

  const { contrast } = validateOrDie(args);

  const apex     = (args.apex || process.env.PUBLIC_BASE_DOMAIN || 'theunionhub.ca').toLowerCase();
  const hostname = `${args.slug}.${apex}`;

  const row = {
    slug:          args.slug,
    display_name:  args.name,
    local_number:  args.local || null,
    union_type:    args['union-type'] || null,
    accent_hex:    args.accent,
    contact_email: args.contact,
    status:        'pending',
  };

  // ─── Plan output ───────────────────────────────────────────────
  log.banner(args['dry-run'] ? 'new-tenant (dry run)' : 'new-tenant');
  log.plan('Plan');
  log.ok_line('slug',         row.slug);
  log.ok_line('name',         row.display_name);
  log.ok_line('local',        row.local_number || c.dim('—'));
  log.ok_line('union_type',   row.union_type   || c.dim('—'));
  log.ok_line('accent',       `${row.accent_hex}  ${c.dim(`(contrast vs ${OFF_WHITE}: ${contrast.toFixed(2)}:1, passes WCAG AA)`)}`);
  log.ok_line('contact',      row.contact_email);
  log.ok_line('apex',         apex);
  log.ok_line('host',         hostname);
  console.log('');

  if (args['dry-run']) {
    log.info('Dry run — no database writes, no DNS check, no email.');
    process.exit(EXIT.OK);
  }

  const t0 = Date.now();
  let tenant;

  // ─── 1. INSERT (status=pending) ────────────────────────────────
  log.step('Inserting tenant (status=pending)');
  try {
    tenant = await sbInsertTenant(row);
    log.ok(`id=${tenant.id}`);
  } catch (e) {
    log.fail(e.message);
    process.exit(/already exists/.test(e.message) ? EXIT.USAGE : EXIT.INFRA);
  }

  // ─── 2. DNS — wait for slug.apex to resolve to Vercel ─────────
  let dnsOk = false;
  if (args['skip-dns']) {
    log.step('DNS check'); log.skip('--skip-dns');
  } else {
    log.step(`DNS check (${hostname} → ${VERCEL_CNAME_TARGET}, up to ${DNS_TOTAL_BUDGET_MS / 60000}m)`);
    const dns = await waitForDns(hostname);
    if (dns.ok) {
      dnsOk = true;
      log.info(`Resolved after ${dns.attempts} attempt${dns.attempts > 1 ? 's' : ''}.`);
    } else {
      log.warn(`DNS did not resolve within budget after ${dns.attempts} attempts.`);
      log.info('Tenant row exists but stays status=pending. Once DNS propagates,');
      log.info(`flip it: UPDATE public.tenants SET status='active' WHERE slug='${row.slug}';`);
    }
  }

  // ─── 3. Activate (only if DNS healthy or skipped intentionally) ─
  if (dnsOk || args['skip-dns']) {
    log.step('Activating tenant (status=active)');
    try {
      tenant = await sbActivateTenant(tenant.id);
      log.ok();
    } catch (e) {
      log.fail(e.message);
      log.info('Tenant row exists at status=pending. You can flip it manually.');
      process.exit(EXIT.PARTIAL_SUCCESS);
    }
  }

  // ─── 4. Audit log row 0 ────────────────────────────────────────
  log.step('Seeding audit_log row 0');
  try {
    const audit = await sbSeedAuditRow(tenant.id, tenant.slug);
    if (audit.skipped === 'table_missing') {
      log.skip("audit_log table doesn't exist yet (migration 0004 not applied)");
    } else {
      log.ok();
    }
  } catch (e) {
    log.warn(`Audit log insert failed: ${e.message}`);
    log.info('Non-fatal. Tenant is still provisioned.');
  }

  // ─── 5. Magic-link ─────────────────────────────────────────────
  if (args['skip-magic-link']) {
    log.step('Magic-link'); log.skip('--skip-magic-link');
  } else {
    log.step(`Sending magic-link to ${row.contact_email}`);
    try {
      await sbSendMagicLink(row.contact_email, `https://${hostname}/auth/callback`);
      log.ok();
    } catch (e) {
      log.warn(e.message);
      log.info('Tenant is provisioned; the admin can request a fresh link from the sign-in page.');
      process.exit(EXIT.PARTIAL_SUCCESS);
    }
  }

  // ─── 6. Done ───────────────────────────────────────────────────
  const elapsed = Math.round((Date.now() - t0) / 1000);
  console.log('');
  console.log(c.green(c.bold(`✓ Provisioned ${row.slug} in ${elapsed}s.`)));
  console.log('');
  console.log(c.dim('Next:'));
  if (!dnsOk && !args['skip-dns']) {
    console.log(c.dim('  · Once DNS propagates, flip status to active in the database.'));
  } else {
    console.log(c.dim(`  · Visit https://${hostname}/card to confirm the card renders in ${row.accent_hex}.`));
  }
  if (!args['skip-magic-link']) {
    console.log(c.dim(`  · ${row.contact_email} will receive the magic-link to sign in.`));
  }
  console.log(c.dim('  · Upload a logo via the admin tools (separate flow).'));
  console.log('');

  process.exit(EXIT.OK);
}

main().catch((e) => {
  log.error('Unexpected error: ' + e.message);
  if (process.env.DEBUG) console.error(e.stack);
  process.exit(EXIT.INFRA);
});
