/* ──────────────────────────────────────────────────────────────
   The Union Hub · live.js
   Self-contained progressive-enhancement script.

   Three features. Each is opt-in: if the markup isn't on the page,
   that feature simply does nothing.

     1. Status pill in the utility bar.
        Upgrades any element with class "util-left" into a live
        green/yellow/red dot + label + clock. Pings Supabase every
        30 seconds. Clock ticks every second.

     2. Live stat counters.
        Any element with [data-live-stat="<key>"] gets its number
        replaced with a live-fetched value, animated on change.
        Current keys: members, verifications_today, locals.

     3. Live roster.
        Any [data-live-roster] container is repopulated every 60s
        from the real Supabase `members` table using the seeded
        demo IDs. The "Synced Xs ago" label ticks every second.

   Respects prefers-reduced-motion: no animation when set.
   No external dependencies. Vanilla DOM.
   ────────────────────────────────────────────────────────────── */
import { resolveConfig } from '/lib/supabase.js';

  /* ---- Config — sourced from the central runtime config in /lib/supabase.js.
     No hardcoded credentials here: resolveConfig() resolves the URL +
     publishable anon key (env / window.__UH_CONFIG__ / RLS-safe prod fallback).
     This file is now an ES module (load it with <script type="module">), so the
     former IIFE wrapper is gone — module scope already isolates these names. ---- */
  var cfg = resolveConfig();
  var SUPABASE_URL = cfg.url;
  var SUPABASE_KEY = cfg.anonKey;

  // DEMO_IDS used to be referenced here for fetchRoster (id=in.(…) query).
  // Removed in the js/→lib/ refactor — the roster now comes from the
  // public_roster() RPC (migration 0012) which curates the demo tenant's
  // members server-side. The three UUIDs still live in seed.sql as the
  // demo data; card.html and verify.html reference them for their
  // ?state= demo links.

  var prefersReduce = window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  var SB_HEADERS = {
    apikey: SUPABASE_KEY,
    Authorization: 'Bearer ' + SUPABASE_KEY
  };

  /* ---- One-time CSS injection ---- */
  function injectStyle() {
    if (document.getElementById('uh-live-style')) return;
    var s = document.createElement('style');
    s.id = 'uh-live-style';
    s.textContent =
      '.util-live{display:inline-flex;align-items:center;gap:10px;}' +
      '.util-live .uh-dot{width:8px;height:8px;border-radius:50%;background:#888780;flex:0 0 auto;transition:background .3s ease;}' +
      '.util-live[data-state="ok"] .uh-dot{background:#1D9E75;animation:uhpulse 2.4s ease-out infinite;}' +
      '.util-live[data-state="degraded"] .uh-dot{background:#C68A1B;}' +
      '.util-live[data-state="down"] .uh-dot{background:#E24B4A;}' +
      '.util-live .uh-state{transition:opacity .2s ease;}' +
      '.util-live .uh-sep{opacity:.5;}' +
      '.util-live .uh-clock{font-variant-numeric:tabular-nums;letter-spacing:.16em;}' +
      '@keyframes uhpulse{0%{box-shadow:0 0 0 0 rgba(29,158,117,.55);}100%{box-shadow:0 0 0 8px rgba(29,158,117,0);}}' +
      '@media (prefers-reduced-motion: reduce){.util-live .uh-dot{animation:none!important;}}' +
      '[data-live-stat]{font-variant-numeric:tabular-nums;}' +
      '[data-live-stat-suffix]{font-variant-numeric:tabular-nums;}' +
      '[data-live-roster]{transition:opacity .4s ease;}' +
      '[data-live-roster][data-stale="1"]{opacity:.55;}' +
      '.uh-live-strip{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));border:0.5px solid rgba(0,0,0,0.15);border-radius:12px;background:#FAF9F5;margin:clamp(28px,4vw,56px) 0;overflow:hidden;}' +
      '.uh-live-cell{padding:24px 26px;border-right:0.5px solid rgba(0,0,0,0.15);border-bottom:0.5px solid rgba(0,0,0,0.15);}' +
      '.uh-live-cell:last-child{border-right:0;}' +
      '.uh-live-cell .label{font-family:"DM Mono",monospace;font-size:10.5px;letter-spacing:.18em;text-transform:uppercase;color:#0F6E56;margin-bottom:10px;display:flex;align-items:center;gap:8px;}' +
      '.uh-live-cell .label .uh-dot{width:7px;height:7px;border-radius:50%;background:#1D9E75;animation:uhpulse 2.4s ease-out infinite;}' +
      '.uh-live-cell .num{font-family:"Playfair Display",serif;font-size:clamp(34px,4vw,48px);font-weight:700;color:#0D1F1A;line-height:1;letter-spacing:-0.01em;}' +
      '.uh-live-cell .sub{font-family:"DM Sans",sans-serif;font-size:13px;color:#888780;margin-top:8px;}' +
      /* Consent banner */
      '.uh-consent{position:fixed;left:22px;bottom:22px;z-index:1000;max-width:380px;padding:18px 22px;background:#FAF9F5;border:0.5px solid rgba(0,0,0,0.15);border-left:1.5px solid #0F6E56;border-radius:12px;font-family:"DM Sans",system-ui,sans-serif;font-size:13.5px;line-height:1.55;color:#2A2A2A;display:flex;align-items:center;gap:16px;flex-wrap:wrap;transform:translateY(24px);opacity:0;transition:transform .4s ease,opacity .4s ease;}' +
      '.uh-consent.is-shown{transform:translateY(0);opacity:1;}' +
      '.uh-consent.is-leaving{transform:translateY(24px);opacity:0;}' +
      '.uh-consent-text{flex:1;min-width:200px;margin:0;}' +
      '.uh-consent-text a{color:#0F6E56;border-bottom:0.5px solid #0F6E56;}' +
      '.uh-consent-text a:hover{color:#1D9E75;border-color:#1D9E75;}' +
      '.uh-consent-ok{display:inline-flex;align-items:center;gap:8px;background:#0F6E56;color:#F5F4F1;border:0;border-radius:8px;padding:9px 18px;font-family:"DM Sans",sans-serif;font-weight:500;font-size:13px;cursor:pointer;transition:background .15s ease;flex:0 0 auto;}' +
      '.uh-consent-ok:hover{background:#1D9E75;}' +
      '@media(prefers-reduced-motion: reduce){.uh-consent{transition:none;transform:none;opacity:1;}.uh-consent.is-leaving{display:none;}}' +
      '@media(max-width:520px){.uh-consent{left:12px;right:12px;bottom:12px;max-width:none;}}' +
      /* Scroll-reveal */
      '.uh-reveal{opacity:0;transform:translateY(14px);transition:opacity .7s cubic-bezier(.2,.7,.2,1),transform .7s cubic-bezier(.2,.7,.2,1);will-change:opacity,transform;}' +
      '.uh-reveal.is-revealed{opacity:1;transform:none;}' +
      '@media(prefers-reduced-motion: reduce){.uh-reveal{opacity:1;transform:none;transition:none;}}';
    document.head.appendChild(s);
  }

  /* =====================================================
   * 1. STATUS PILL
   * ===================================================*/
  function upgradeStatusBar() {
    var els = document.querySelectorAll('.util-left:not(.util-live)');
    els.forEach(function (el) {
      el.classList.add('util-live');
      el.setAttribute('data-state', 'pending');
      el.innerHTML =
        '<span class="uh-dot"></span>' +
        '<span class="uh-state">Connecting</span>' +
        '<span class="uh-sep">·</span>' +
        '<span class="uh-clock">--:--:--</span>';
    });
  }

  // Ping a known-good RLS-allowed endpoint: lookup by the all-zero UUID.
  // Returns 200 with an empty array when healthy.
  var EMPTY_UUID = '00000000-0000-0000-0000-000000000000';
  function pingSupabase() {
    var t0 = performance.now();
    return fetch(SUPABASE_URL + '/rest/v1/members?id=eq.' + EMPTY_UUID + '&select=id', {
      headers: SB_HEADERS,
      cache: 'no-store'
    }).then(function (r) {
      var ms = performance.now() - t0;
      if (!r.ok)     return { state: 'down', ms: ms };
      if (ms > 800)  return { state: 'degraded', ms: ms };
      return { state: 'ok', ms: ms };
    }).catch(function () {
      return { state: 'down', ms: performance.now() - t0 };
    });
  }

  var STATE_LABEL = {
    ok:       'Live · synced',
    degraded: 'Live · slow',
    down:     'Reconnecting',
    pending:  'Connecting'
  };

  function paintStatus(result) {
    document.querySelectorAll('.util-live').forEach(function (el) {
      el.setAttribute('data-state', result.state);
      var s = el.querySelector('.uh-state');
      if (s) s.textContent = STATE_LABEL[result.state] || 'Live';
    });
  }

  function updateClock() {
    var d = new Date();
    var hh = String(d.getHours()).padStart(2, '0');
    var mm = String(d.getMinutes()).padStart(2, '0');
    var ss = String(d.getSeconds()).padStart(2, '0');
    var t = hh + ':' + mm + ':' + ss + ' ET';
    document.querySelectorAll('.util-live .uh-clock').forEach(function (el) {
      el.textContent = t;
    });
  }

  /* =====================================================
   * 2. LIVE STATS
   *    Calls public.public_stats() (SECURITY DEFINER, migration 0003)
   *    so the apex marketing page sees real global counts even though
   *    it carries no x-tenant-id — without that function, the post-
   *    0002 RLS on members would return 0 rows here.
   *    The function returns aggregate counts only; never row data.
   * ===================================================*/
  function fetchStats() {
    return fetch(SUPABASE_URL + '/rest/v1/rpc/public_stats', {
      headers: SB_HEADERS,
      cache: 'no-store'
    })
    .then(function (r) { return r.ok ? r.json() : []; })
    .then(function (rows) {
      var row = (rows && rows[0]) || {};
      // Alias to the data-live-stat keys the marketing HTML already uses.
      return {
        members:             row.members_count,
        verifications_today: row.verifications_today,
        locals:              row.locals_count
      };
    })
    .catch(function () { return {}; });
  }

  function animateNumber(el, from, to, durationMs) {
    if (prefersReduce || !durationMs) {
      el.textContent = formatNumber(to);
      return;
    }
    var t0 = performance.now();
    function step(t) {
      var k = Math.min(1, (t - t0) / durationMs);
      var eased = 1 - Math.pow(1 - k, 3);
      var v = Math.round(from + (to - from) * eased);
      el.textContent = formatNumber(v);
      if (k < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
  }

  function formatNumber(n) {
    return Number(n).toLocaleString('en-CA');
  }

  function paintStats(stats) {
    document.querySelectorAll('[data-live-stat]').forEach(function (el) {
      var key = el.getAttribute('data-live-stat');
      if (!(key in stats)) return;
      var target = stats[key];
      var prev = parseInt((el.textContent || '').replace(/[^\d-]/g, ''), 10);
      if (!isFinite(prev)) prev = 0;
      animateNumber(el, prev, target, 800);
    });
  }

  /* =====================================================
   * 3. LIVE ROSTER
   *    Calls public.public_roster() (SECURITY DEFINER, migration
   *    0012) so the apex marketing page sees a curated demo roster
   *    without the post-0008 admin-only RLS on members blocking it.
   *    The RPC returns only the demo tenant's members, capped at
   *    50 rows server-side. We pass no p_limit — the default (10) is
   *    plenty for the strip.
   * ===================================================*/
  function fetchRoster() {
    return fetch(SUPABASE_URL + '/rest/v1/rpc/public_roster', {
      headers: SB_HEADERS,
      cache: 'no-store'
    })
      .then(function (r) { return r.ok ? r.json() : []; })
      .catch(function () { return []; });
  }

  var STATUS_CLASS = {
    active:    'roster-status',
    inactive:  'roster-status invalid',
    suspended: 'roster-status invalid',
    lapsed:    'roster-status invalid'
  };

  var STATUS_LABEL = {
    active:    'Active',
    inactive:  'Inactive',
    suspended: 'Suspended',
    lapsed:    'Lapsed'
  };

  function escapeHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' })[c];
    });
  }

  function paintRoster(rows) {
    var roster = document.querySelector('[data-live-roster]');
    if (!roster) return;
    var listEl = roster.querySelector('[data-live-roster-list]');
    if (!listEl || !rows.length) {
      // Keep static demo content if fetch failed.
      return;
    }
    var order = { active: 0, inactive: 1, suspended: 2, lapsed: 2 };
    rows.sort(function (a, b) {
      return ((order[a.status] != null ? order[a.status] : 9)) -
             ((order[b.status] != null ? order[b.status] : 9));
    });
    listEl.innerHTML = rows.map(function (m) {
      var year = m.member_since ? new Date(m.member_since).getFullYear() : '';
      var st = (m.status || '').toLowerCase();
      var cls = STATUS_CLASS[st] || 'roster-status';
      var lab = STATUS_LABEL[st] || (st ? st.charAt(0).toUpperCase() + st.slice(1) : '—');
      var since = year ? (st === 'active' ? 'Active since ' + year : 'Member since ' + year) : '';
      return '<div class="roster-row">' +
              '<div><span class="roster-name">' + escapeHtml(m.full_name) + '</span>' +
                '<div class="roster-id">UH–' + escapeHtml((m.id || '').slice(0, 8)) + '</div></div>' +
              '<span class="roster-id">' + escapeHtml(since) + '</span>' +
              '<span class="' + cls + '">' + escapeHtml(lab) + '</span>' +
            '</div>';
    }).join('');
    roster.setAttribute('data-stale', '0');
    roster.dataset.fetchedAt = String(Date.now());
    var countEl = roster.querySelector('[data-live-roster-count]');
    if (countEl) countEl.textContent = formatNumber(rows.length);
  }

  function tickRosterStaleness() {
    document.querySelectorAll('[data-live-roster]').forEach(function (roster) {
      var sync = roster.querySelector('[data-live-roster-synced]');
      var t = parseInt(roster.dataset.fetchedAt, 10);
      if (!sync || !t) return;
      var elapsed = Math.max(0, Math.floor((Date.now() - t) / 1000));
      var label;
      if (elapsed < 5)       label = 'Synced just now';
      else if (elapsed < 60) label = 'Synced ' + elapsed + 's ago';
      else                   label = 'Synced ' + Math.floor(elapsed / 60) + 'm ago';
      sync.textContent = label;
      if (elapsed > 75) roster.setAttribute('data-stale', '1');
    });
  }

  /* =====================================================
   * 4. SCROLL REVEAL
   *    Section-level fade-up as elements enter the viewport.
   *    Graceful degradation: if IntersectionObserver is missing
   *    or prefers-reduced-motion is set, the .uh-reveal class is
   *    never added, so content stays visible from the start.
   * ===================================================*/
  function initReveals() {
    if (prefersReduce) return;
    if (!('IntersectionObserver' in window)) return;

    var sel = [
      'header.hero',
      'header.page-head',
      'body > section',
      'main > section',
      '.prose-body > section',
      '.prose > section'
    ].join(', ');

    var nodes = document.querySelectorAll(sel);
    if (!nodes.length) return;

    nodes.forEach(function (n) { n.classList.add('uh-reveal'); });

    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-revealed');
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.08, rootMargin: '0px 0px -8% 0px' });

    nodes.forEach(function (n) { io.observe(n); });
  }

  /* =====================================================
   * 5. CONSENT BANNER
   *    One-line acceptance with links to Terms and Privacy.
   *    Persists dismissal in localStorage so it never re-shows.
   * ===================================================*/
  var CONSENT_KEY = 'uh_consent_v1';

  function safeGetConsent() {
    try { return localStorage.getItem(CONSENT_KEY); } catch (e) { return null; }
  }
  function safeSetConsent() {
    try { localStorage.setItem(CONSENT_KEY, '1'); } catch (e) {}
  }

  function showConsent() {
    if (safeGetConsent()) return;

    var banner = document.createElement('div');
    banner.className = 'uh-consent';
    banner.setAttribute('role', 'dialog');
    banner.setAttribute('aria-label', 'Terms and privacy notice');
    banner.innerHTML =
      '<p class="uh-consent-text">By using this site you accept our ' +
      '<a href="terms.html">Terms</a> and <a href="privacy.html">Privacy notice</a>.</p>' +
      '<button class="uh-consent-ok" type="button">Accept</button>';

    document.body.appendChild(banner);

    // Two RAFs to make sure the initial transform is committed before transitioning
    requestAnimationFrame(function () {
      requestAnimationFrame(function () { banner.classList.add('is-shown'); });
    });

    function dismiss() {
      safeSetConsent();
      banner.classList.remove('is-shown');
      banner.classList.add('is-leaving');
      setTimeout(function () { if (banner.parentNode) banner.parentNode.removeChild(banner); }, 450);
    }

    banner.querySelector('.uh-consent-ok').addEventListener('click', dismiss);
  }

  /* =====================================================
   * Boot
   * ===================================================*/
  function boot() {
    injectStyle();
    upgradeStatusBar();
    updateClock();

    pingSupabase().then(paintStatus);
    fetchStats().then(paintStats);
    fetchRoster().then(paintRoster);

    // Cadence
    setInterval(updateClock, 1000);
    setInterval(function () { pingSupabase().then(paintStatus); }, 30000);
    setInterval(function () { fetchStats().then(paintStats); }, 60000);
    setInterval(function () { fetchRoster().then(paintRoster); }, 60000);
    setInterval(tickRosterStaleness, 1000);

    // Scroll-reveal: gate sections behind a fade-up as they enter the viewport.
    initReveals();

    // Consent banner — small delay so it doesn't compete with first paint.
    setTimeout(showConsent, 600);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
