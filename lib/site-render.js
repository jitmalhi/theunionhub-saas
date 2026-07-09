/* ──────────────────────────────────────────────────────────────────────────
   lib/site-render.js
   Server-side renderer for Tier-1 public union-local websites.

   Pure function: renderSitePage(site) → a complete, self-contained HTML string.
   No client-side data fetching, no framework — the edge/serverless route calls
   this with the jsonb blob from get_public_site() (0038) and returns the HTML.
   Semantic HTML, real <table> for stewards, inlined CSS, minimal JS. Fast on a
   several-year-old Android over 3G.

   Template #1 = "Editorial / Professional Association" (Direction B): a quiet
   news-serif for headings + a clean sans for body, ivory paper, slate ink, one
   per-tenant accent token. Templates civic/modern share this structure and swap
   the type + palette tokens (future).

   This module is server-side ONLY (Node) — hence the relative import. All
   tenant/member-supplied strings pass through esc() before hitting HTML.
   ────────────────────────────────────────────────────────────────────────── */

import { esc } from './escape.js';

/* ── small helpers ── */
const A = (v) => Array.isArray(v) ? v : [];
const has = (v) => v != null && String(v).trim() !== '';
const nl2 = (s) => esc(s).replace(/\r?\n/g, '<br>');

function fmtDate(iso) {
  if (!iso) return '';
  // Deterministic, locale-stable formatting (no Intl surprises across runtimes).
  const d = new Date(iso);
  if (isNaN(d)) return '';
  const M = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  return `${M[d.getUTCMonth()]} ${d.getUTCDate()}, ${d.getUTCFullYear()}`;
}
function fmtDateTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d)) return '';
  const days = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
  const M = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  let h = d.getUTCHours(), m = d.getUTCMinutes();
  const ap = h >= 12 ? 'PM' : 'AM'; h = h % 12 || 12;
  const mm = m === 0 ? '' : ':' + String(m).padStart(2, '0');
  return `${days[d.getUTCDay()]}, ${M[d.getUTCMonth()]} ${d.getUTCDate()} · ${h}${mm} ${ap}`;
}

/* ── the template ── */
export function renderSitePage(site) {
  const st       = site.settings || {};
  const tenant   = site.tenant || {};
  const accent   = /^#[0-9a-fA-F]{6}$/.test(st.accent_hex || '') ? st.accent_hex : '#2F5D7C';
  const localNo  = tenant.local_number;
  const siteName = has(st.site_name) ? st.site_name : (tenant.display_name || `Local ${localNo || ''}`);
  const parent   = st.parent_union_name;
  const crest    = localNo ? esc(String(localNo)) : '·';

  // Which sections actually render (toggle AND has content).
  const alert    = st.show_alert    && site.alert ? site.alert : null;
  const posts    = st.show_updates  ? A(site.posts).slice(0, 6) : [];
  const showAbout = st.show_about && (has(st.site_name) || has(tenant.display_name) || has(st.about_body));
  // Facts panel: the local's custom key/values, else sensible defaults.
  const customFacts = A(st.about_facts).filter(f => f && has(f.label) && has(f.value));
  const aboutFacts = customFacts.length ? customFacts : [
    (st.member_count != null) ? { label: 'Members', value: String(st.member_count) } : null,
    st.charter_year ? { label: 'Chartered', value: String(st.charter_year) } : null,
    A(site.stewards).length ? { label: 'Stewards', value: String(A(site.stewards).length) } : null,
    has(st.municipality) ? { label: 'Location', value: st.municipality } : null,
  ].filter(Boolean);
  const officers = st.show_executive ? A(site.officers) : [];
  const stewards = st.show_stewards  ? A(site.stewards) : [];
  const meetings = st.show_meetings  ? A(site.meetings) : [];
  const featured = meetings.filter(m => m.meeting_type === 'featured');
  const schedule = meetings.filter(m => m.meeting_type === 'schedule');
  const docs     = st.show_documents ? A(site.documents) : [];

  // Nav links, auto-generated from what's present.
  const nav = [];
  if (showAbout)        nav.push(['#about', 'About']);
  if (posts.length)     nav.push(['#updates', 'Updates']);
  if (officers.length)  nav.push(['#executive', 'Executive']);
  if (stewards.length)  nav.push(['#stewards', 'Stewards']);
  if (meetings.length)  nav.push(['#meetings', 'Meetings']);
  if (docs.length)      nav.push(['#documents', 'Documents']);
  nav.push(['#contact', 'Contact']);

  const title = `${siteName}${localNo && !/local/i.test(siteName) ? ` · Local ${esc(String(localNo))}` : ''}`;
  const desc  = has(st.meta_description) ? st.meta_description
              : has(st.tagline) ? st.tagline
              : `${siteName} — official website.`;
  const canonical = site.primary_host ? `https://${esc(site.primary_host)}/` : '';

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${esc(title)}</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="${esc(desc)}">
${canonical ? `<link rel="canonical" href="${canonical}">` : ''}
<meta property="og:type" content="website">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(desc)}">
${canonical ? `<meta property="og:url" content="${canonical}">` : ''}
<meta name="twitter:card" content="summary">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Newsreader:opsz,wght@6..72,400;6..72,500;6..72,600&family=Public+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
  :root{
    --paper:#fbf9f4;--paper-2:#f4f0e7;--ink:#23252b;--ink-soft:#3d4149;--muted:#6d6f78;
    --line:#e6e0d3;--line-soft:#eee9dd;--accent:${accent};--focus:${accent};--maxw:1000px;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--paper);color:var(--ink-soft);font-family:'Public Sans',system-ui,-apple-system,sans-serif;font-size:17px;line-height:1.7;-webkit-font-smoothing:antialiased}
  h1,h2,h3{font-family:'Newsreader',Georgia,serif;color:var(--ink);font-weight:500;line-height:1.14;margin:0;letter-spacing:-.005em}
  a{color:var(--accent);text-underline-offset:2px;text-decoration-thickness:1px}
  a:hover{color:var(--ink)}
  :focus-visible{outline:3px solid var(--focus);outline-offset:2px}
  img{max-width:100%;height:auto}
  .wrap{max-width:var(--maxw);margin:0 auto;padding:0 24px}
  .eyebrow{font-size:12px;font-weight:700;letter-spacing:.16em;text-transform:uppercase;color:var(--accent);margin:0 0 12px}
  .rule{width:46px;height:2px;background:var(--accent);margin:0 0 22px}
  section{padding:60px 0}section+section{border-top:1px solid var(--line-soft)}
  section>.wrap>h2{font-size:clamp(27px,4vw,36px);margin-bottom:10px}
  .lede{font-size:19px;color:var(--muted);max-width:62ch}
  .skip{position:absolute;left:-9999px}.skip:focus{left:12px;top:12px;background:#fff;padding:10px 14px;border:2px solid var(--accent);z-index:50}
  .alert{background:var(--accent);color:#fff}
  .alert .wrap{display:flex;gap:14px;align-items:baseline;flex-wrap:wrap;padding:13px 24px;font-size:15.5px}
  .alert .tag{font-size:11px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;border:1px solid rgba(255,255,255,.45);padding:3px 9px;border-radius:2px}
  .alert a{color:#fff;font-weight:600}
  header.site{background:var(--paper);border-bottom:1px solid var(--line)}
  .mast{display:flex;align-items:center;gap:16px;padding:22px 0;flex-wrap:wrap}
  .crest{width:50px;height:50px;border-radius:3px;background:var(--accent);color:#fff;display:grid;place-items:center;font-family:'Newsreader',serif;font-weight:600;font-size:19px;flex:none}
  .crest img{width:100%;height:100%;object-fit:contain;border-radius:3px}
  .id .local{font-family:'Newsreader',serif;font-weight:600;color:var(--ink);font-size:21px;line-height:1.1}
  .id .parent{font-size:13px;color:var(--muted)}
  .mast nav{margin-left:auto}
  .mast nav ul{display:flex;gap:4px;list-style:none;margin:0;padding:0;flex-wrap:wrap}
  .mast nav a{color:var(--ink-soft);text-decoration:none;font-weight:600;font-size:14px;padding:7px 11px;border-radius:3px}
  .mast nav a:hover{background:var(--paper-2);color:var(--ink)}
  .hero{padding:56px 0 50px}
  .hero h1{font-size:clamp(32px,6vw,56px);font-weight:500;max-width:17ch}
  .hero .tagline{font-size:clamp(18px,2.6vw,22px);color:var(--ink-soft);font-style:italic;font-family:'Newsreader',serif;margin:18px 0 28px;max-width:46ch}
  .facts{display:flex;gap:40px;flex-wrap:wrap;padding-top:22px;border-top:1px solid var(--line)}
  .facts .n{font-family:'Newsreader',serif;font-weight:500;color:var(--ink);font-size:29px}
  .facts .k{font-size:12.5px;color:var(--muted);text-transform:uppercase;letter-spacing:.09em}
  .post{padding:24px 0;border-bottom:1px solid var(--line-soft);display:grid;grid-template-columns:150px 1fr;gap:24px}
  .post .meta{font-size:14px;color:var(--muted)}
  .pin{display:inline-block;font-size:10.5px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--accent);border:1px solid var(--accent);padding:2px 7px;border-radius:2px;margin-bottom:8px}
  .post h3{font-size:22px;margin-bottom:6px;font-weight:600}
  .post .body{max-width:66ch}.post .body :first-child{margin-top:0}.post .body :last-child{margin-bottom:0}
  .about-grid{display:grid;grid-template-columns:1.7fr 1fr;gap:48px;align-items:start}
  .about-body p{max-width:60ch}
  .facts-panel{background:var(--paper-2);border-radius:4px;padding:26px 28px;border-top:3px solid var(--accent)}
  .facts-panel h3{font-family:'Public Sans',sans-serif;font-size:12.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--accent);margin-bottom:14px;font-weight:700}
  .facts-panel .row{display:flex;justify-content:space-between;gap:16px;padding:9px 0;border-bottom:1px solid var(--line)}
  .facts-panel .row:last-child{border-bottom:0}
  .facts-panel dt{color:var(--muted);font-size:15px;margin:0}.facts-panel dd{margin:0;font-weight:600;color:var(--ink)}
  .officer{display:grid;grid-template-columns:220px 1fr;gap:20px;padding:18px 0;border-bottom:1px solid var(--line-soft);align-items:baseline}
  .officers{border-top:1px solid var(--line)}
  .officer .role{font-family:'Newsreader',serif;font-size:20px;color:var(--ink);font-weight:500}
  .officer .name{font-weight:700;color:var(--accent);font-size:16px}.officer .desc{font-size:14.5px;color:var(--muted)}
  #stewards{background:var(--paper-2)}
  .table-card{background:var(--paper);border:1px solid var(--line);border-radius:4px;overflow-x:auto}
  table.stewards{width:100%;border-collapse:collapse;font-size:16px;min-width:520px}
  table.stewards caption{font-family:'Newsreader',serif;text-align:left;padding:16px 20px;font-size:19px;color:var(--ink);border-bottom:1px solid var(--line)}
  table.stewards th,table.stewards td{text-align:left;padding:14px 20px;border-bottom:1px solid var(--line-soft);vertical-align:top}
  table.stewards thead th{font-family:'Public Sans';font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);font-weight:700}
  table.stewards tbody tr:last-child td{border-bottom:0}
  table.stewards .who{font-weight:700;color:var(--ink)}
  .rights{margin-top:20px;font-family:'Newsreader',serif;font-size:18px;line-height:1.55;color:var(--ink-soft);padding-left:20px;border-left:3px solid var(--accent)}
  .rights strong{color:var(--ink);font-weight:600}
  .meet-grid{display:grid;grid-template-columns:1fr 1fr;gap:40px;align-items:start}
  .next-meeting{border:1px solid var(--line);border-radius:4px;padding:28px;background:var(--paper)}
  .next-meeting .when{font-family:'Newsreader',serif;font-size:28px;font-weight:500;color:var(--ink)}
  .next-meeting .what{color:var(--accent);font-weight:600;margin:6px 0 14px}.next-meeting .where{color:var(--ink-soft)}
  .schedule .row{display:flex;justify-content:space-between;gap:16px;padding:13px 0;border-bottom:1px solid var(--line)}
  .schedule .lbl{color:var(--ink);font-weight:600}.schedule .val{color:var(--muted);font-family:'Newsreader',serif;font-style:italic}
  .docs{border-top:1px solid var(--line)}
  .doc{display:flex;gap:16px;align-items:center;padding:18px 4px;border-bottom:1px solid var(--line-soft);text-decoration:none}
  .doc:hover .t{color:var(--accent)}
  .doc .ic{width:30px;height:38px;flex:none;border:1px solid var(--line);border-radius:2px;background:var(--paper-2)}
  .doc .t{font-family:'Newsreader',serif;font-size:20px;color:var(--ink);font-weight:500}.doc .m{font-size:13.5px;color:var(--muted)}
  footer.site{background:var(--ink);color:#c3c6cd;padding:52px 0 32px;font-size:15px}
  footer.site a{color:#eceef1}
  .foot-grid{display:grid;grid-template-columns:1.5fr 1fr 1fr;gap:36px}
  footer.site h4{font-family:'Newsreader',serif;color:#fff;font-size:18px;font-weight:500;margin:0 0 12px}
  footer.site ul{list-style:none;margin:0;padding:0}footer.site li{margin-bottom:7px}
  .foot-bottom{margin-top:36px;padding-top:20px;border-top:1px solid rgba(255,255,255,.14);display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap;font-size:13.5px;color:#9a9da5}
  .credit{display:inline-flex;align-items:center;gap:8px}.credit .dot{width:15px;height:15px;border-radius:50%;background:#1e9e75}.credit a{color:#fff;font-weight:600}
  @media(max-width:820px){.about-grid,.meet-grid{grid-template-columns:1fr;gap:26px}.post{grid-template-columns:1fr;gap:6px}.officer{grid-template-columns:1fr;gap:2px}.foot-grid{grid-template-columns:1fr;gap:26px}.mast nav{margin-left:0;width:100%}}
  @media(prefers-reduced-motion:reduce){*{transition:none!important}}
</style>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
${alert ? `<div class="alert" role="region" aria-label="Urgent notice"><div class="wrap">
  <span class="tag">Notice</span>
  <span>${esc(alert.message)}${has(alert.link_url) ? ` <a href="${esc(alert.link_url)}">${esc(alert.link_label || 'Details')}</a>` : ''}</span>
</div></div>` : ''}

<header class="site">
  <div class="wrap mast">
    <div class="crest" aria-hidden="true">${has(st.logo_url) ? `<img src="${esc(st.logo_url)}" alt="">` : crest}</div>
    <div class="id">
      <div class="local">${esc(localNo ? `Local ${localNo}` : siteName)}</div>
      ${has(parent) ? `<div class="parent">${esc(parent)}</div>` : ''}
    </div>
    <nav aria-label="Primary"><ul>${nav.map(([h, l]) => `<li><a href="${h}">${esc(l)}</a></li>`).join('')}</ul></nav>
  </div>
</header>

<div class="hero">
  <div class="wrap">
    ${(has(st.municipality) || st.charter_year) ? `<p class="eyebrow">${[has(st.municipality) ? esc(st.municipality) : null, st.charter_year ? `Chartered ${esc(String(st.charter_year))}` : null].filter(Boolean).join(' · ')}</p>` : ''}
    <h1>${esc(siteName)}</h1>
    ${has(st.tagline) ? `<p class="tagline">${esc(st.tagline)}</p>` : ''}
    <div class="facts">
      ${(st.show_member_count && st.member_count != null) ? `<div><div class="n">${esc(String(st.member_count))}</div><div class="k">Members</div></div>` : ''}
      ${stewards.length ? `<div><div class="n">${stewards.length}</div><div class="k">Stewards</div></div>` : ''}
      ${st.charter_year ? `<div><div class="n">${esc(String(st.charter_year))}</div><div class="k">Chartered</div></div>` : ''}
    </div>
  </div>
</div>

<main id="main">
${posts.length ? `<section id="updates"><div class="wrap">
  <p class="eyebrow">Notices</p><h2>Updates from the local</h2><div class="rule"></div>
  ${posts.map(p => `<article class="post">
    <div class="meta">${p.pinned ? `<span class="pin">Pinned</span><br>` : ''}<time datetime="${esc(p.published_at || '')}">${esc(fmtDate(p.published_at))}</time></div>
    <div><h3>${esc(p.title)}</h3><div class="body">${p.body || ''}</div></div>
  </article>`).join('')}
</div></section>` : ''}

${showAbout ? `<section id="about"><div class="wrap about-grid">
  <div class="about-body">
    <p class="eyebrow">About the local</p><h2>Who we are</h2><div class="rule"></div>
    ${has(st.about_body) ? `<p>${nl2(st.about_body)}</p>` : `<p>${esc(siteName)}${has(parent) ? `, part of ${esc(parent)},` : ''} represents its members${has(st.municipality) ? ` in ${esc(st.municipality)}` : ''}.</p>`}
  </div>
  <aside class="facts-panel" aria-label="At a glance">
    <h3>At a glance</h3>
    <dl>${aboutFacts.map(f => `<div class="row"><dt>${esc(f.label)}</dt><dd>${esc(f.value)}</dd></div>`).join('')}</dl>
  </aside>
</div></section>` : ''}

${officers.length ? `<section id="executive"><div class="wrap">
  <p class="eyebrow">Elected officers</p><h2>Executive board</h2><div class="rule"></div>
  <div class="officers">${officers.map(o => `<div class="officer">
    <div class="role">${esc(o.role_title)}</div>
    <div><div class="name">${esc(o.display_name)}</div>${has(o.descriptor) ? `<div class="desc">${esc(o.descriptor)}</div>` : ''}${has(o.email) ? `<div class="desc"><a href="mailto:${esc(o.email)}">${esc(o.email)}</a></div>` : ''}</div>
  </div>`).join('')}</div>
</div></section>` : ''}

${stewards.length ? `<section id="stewards"><div class="wrap">
  <p class="eyebrow">Your stewards</p><h2>Find your steward</h2>
  <p class="lede" style="margin:10px 0 24px">Stewards represent you at work. If you have a workplace problem, start here.</p>
  <div class="table-card"><table class="stewards"><caption>Stewards by shift and area</caption>
    <thead><tr><th scope="col">Shift</th><th scope="col">Area</th><th scope="col">Steward</th><th scope="col">Contact</th></tr></thead>
    <tbody>${stewards.map(w => `<tr>
      <td>${esc(w.shift || '')}</td><td>${esc(w.area || '')}</td>
      <td class="who">${esc(w.steward_name)}</td>
      <td>${has(w.contact_method) ? (/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(w.contact_method) ? `<a href="mailto:${esc(w.contact_method)}">${esc(w.contact_method)}</a>` : esc(w.contact_method)) : '—'}</td>
    </tr>`).join('')}</tbody>
  </table></div>
  ${has(st.stewards_rights_blurb) ? `<p class="rights"><strong>Your right to representation.</strong> ${esc(st.stewards_rights_blurb)}</p>` : ''}
</div></section>` : ''}

${meetings.length ? `<section id="meetings"><div class="wrap">
  <p class="eyebrow">Meetings</p><h2>When we meet</h2><div class="rule"></div>
  <div class="meet-grid">
    ${featured.length ? `<div class="next-meeting">
      <p class="eyebrow" style="margin-bottom:6px">Next meeting</p>
      <div class="when">${esc(fmtDateTime(featured[0].starts_at) || featured[0].title)}</div>
      <div class="what">${esc(featured[0].title)}</div>
      ${has(featured[0].location) || has(featured[0].notes) ? `<div class="where">${[has(featured[0].location) ? esc(featured[0].location) : null, has(featured[0].notes) ? esc(featured[0].notes) : null].filter(Boolean).join('. ')}</div>` : ''}
    </div>` : ''}
    ${schedule.length ? `<div class="schedule"><p class="eyebrow" style="margin-bottom:6px">Regular schedule</p>
      ${schedule.map(s => `<div class="row"><span class="lbl">${esc(s.title)}</span><span class="val">${esc(s.schedule_note || '')}</span></div>`).join('')}
    </div>` : ''}
  </div>
</div></section>` : ''}

${docs.length ? `<section id="documents"><div class="wrap">
  <p class="eyebrow">Documents</p><h2>Forms &amp; downloads</h2><div class="rule"></div>
  <div class="docs">${docs.map(d => `<a class="doc" href="${has(d.storage_path) ? esc(d.storage_path) : '#'}">
    <span class="ic" aria-hidden="true"></span>
    <span><span class="t">${esc(d.title)}</span>${has(d.meta) ? `<br><span class="m">${esc(d.meta)}</span>` : ''}</span>
  </a>`).join('')}</div>
</div></section>` : ''}
</main>

<footer class="site" id="contact">
  <div class="wrap">
    <div class="foot-grid">
      <div>
        <h4>${esc(localNo ? `Local ${localNo}` : siteName)}</h4>
        ${has(parent) ? `<p style="margin:0 0 4px">${esc(parent)}</p>` : ''}
        ${has(st.office_address) ? `<p style="margin:0;color:#9a9da5">${nl2(st.office_address)}</p>` : ''}
      </div>
      <div><h4>Contact</h4><ul>
        ${has(st.contact_email) ? `<li><a href="mailto:${esc(st.contact_email)}">${esc(st.contact_email)}</a></li>` : ''}
        ${has(st.contact_phone) ? `<li>${esc(st.contact_phone)}</li>` : ''}
      </ul></div>
      <div><h4>On this site</h4><ul>${nav.filter(([h]) => h !== '#contact').map(([h, l]) => `<li><a href="${h}">${esc(l)}</a></li>`).join('')}</ul></div>
    </div>
    <div class="foot-bottom">
      <span>${has(st.affiliations) ? nl2(st.affiliations) : (has(parent) ? `Affiliated with ${esc(parent)}` : '')}</span>
      <span class="credit"><span class="dot" aria-hidden="true"></span><span>Built with <a href="https://theunionhub.ca">The Union Hub</a></span></span>
    </div>
  </div>
</footer>
</body>
</html>`;
}

export default renderSitePage;
