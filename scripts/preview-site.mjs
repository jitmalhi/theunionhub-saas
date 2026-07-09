#!/usr/bin/env node
/* ──────────────────────────────────────────────────────────────────────────
   scripts/preview-site.mjs
   Renders the Tier-1 site template with the canonical Local 412 fixture (the
   same shape get_public_site() returns) and writes a browsable HTML file into
   the UX design folder. This is the REAL production template output — proof the
   renderer works end-to-end, and a page to eyeball before wiring the DB.
   Run:  node scripts/preview-site.mjs
   ────────────────────────────────────────────────────────────────────────── */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { renderSitePage } from '../lib/site-render.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Fixture = exactly the jsonb shape get_public_site() returns (Local 412,
// per UX design/MOCKUP-RULES.md). Dates anchored to mid-July 2026.
const site = {
  tenant: {
    id: '00000000-0000-4000-8000-000000000412',
    slug: 'local412',
    local_number: '412',
    display_name: 'Allied Health & Service Workers, Local 412',
    logo_url: null,
  },
  primary_host: 'local412.theunionhub.ca',
  settings: {
    template: 'editorial', accent_hex: '#2F5D7C', published: true,
    show_alert: true, show_updates: true, show_about: true, show_executive: true,
    show_stewards: true, show_meetings: true, show_documents: true,
    site_name: 'Allied Health & Service Workers, Local 412',
    tagline: 'Representing healthcare workers at Lakeview Regional Health Centre since 1974.',
    municipality: 'Riverbend', charter_year: 1974,
    parent_union_name: 'Allied Health & Service Workers',
    member_count: 340, show_member_count: true, logo_url: null,
    about_body: 'Local 412 represents roughly 340 healthcare workers — nurses, personal support workers, diagnostic and support staff — at Lakeview Regional Health Centre in Riverbend. We have held our charter since 1974.\n\nOur work is straightforward: enforce the collective agreement, represent members in grievances and discipline, keep workplaces safe, and bargain a fair contract.',
    about_facts: [
      { label: 'Members', value: '~340' },
      { label: 'Chartered', value: '1974' },
      { label: 'Agreement term', value: '2023–2026' },
      { label: 'Stewards', value: '8' },
      { label: 'Employer', value: 'Lakeview Regional' },
    ],
    stewards_rights_blurb: 'You have the right to have a steward present in any meeting with management that could lead to discipline. If you are called into such a meeting, you may ask to pause and contact your steward before it continues.',
    office_address: 'Union office\n118 Riverbend Main St, Suite 4\nRiverbend',
    contact_email: 'info@local412.example', contact_phone: '(555) 018-0412',
    affiliations: 'Affiliated with Allied Health & Service Workers · Riverbend & District Labour Council',
    meta_description: 'Allied Health & Service Workers, Local 412 — representing healthcare workers at Lakeview Regional Health Centre in Riverbend since 1974.',
  },
  alert: {
    message: 'Bargaining update meeting — Thursday, July 16, 2026, 6:30 PM, Riverbend Community Hall.',
    link_url: '#meetings', link_label: 'Details', expires_at: '2026-07-17T00:00:00Z',
  },
  posts: [
    { title: 'Tentative dates set for renewal bargaining', pinned: true, published_at: '2026-07-02T12:00:00Z',
      body: '<p>The bargaining committee has confirmed dates with the employer for renewal of the 2023–2026 agreement. A membership update meeting is scheduled for July 16 — all members are encouraged to attend.</p>' },
    { title: 'Q2 membership meeting recap', pinned: false, published_at: '2026-06-18T12:00:00Z',
      body: '<p>Minutes and the treasurer’s report from the June general meeting are now posted under Documents. Thank you to everyone who attended.</p>' },
    { title: 'New health & safety representatives posted', pinned: false, published_at: '2026-06-05T12:00:00Z',
      body: '<p>Two new worker representatives have joined the joint health and safety committee. Contact your steward to raise a concern for the next meeting.</p>' },
  ],
  officers: [
    { role_title: 'President', display_name: 'M. Delgado', descriptor: 'Chief spokesperson & bargaining lead', email: null },
    { role_title: 'Vice-President', display_name: 'A. Kaur', descriptor: 'Grievances & membership', email: null },
    { role_title: 'Secretary-Treasurer', display_name: 'R. Whitefeather', descriptor: 'Finances & records', email: null },
    { role_title: 'Recording Secretary', display_name: 'T. Okafor', descriptor: 'Minutes & correspondence', email: null },
  ],
  stewards: [
    { shift: 'Days', area: 'Emergency & ICU', steward_name: 'E. Vance · Chief Steward', contact_method: 'evance@local412.example' },
    { shift: 'Days', area: 'Medical / Surgical', steward_name: 'S. Brar', contact_method: 'sbrar@local412.example' },
    { shift: 'Nights', area: 'Long-Term Care', steward_name: 'J. Osei', contact_method: 'josei@local412.example' },
    { shift: 'Rotating', area: 'Diagnostic Imaging', steward_name: 'P. Lindgren', contact_method: 'plindgren@local412.example' },
  ],
  meetings: [
    { meeting_type: 'featured', title: 'General Membership Meeting', starts_at: '2026-07-21T19:00:00Z', location: 'Riverbend Community Hall, 40 Main St', notes: 'All members welcome; bring your membership card', schedule_note: null, sort_order: 0 },
    { meeting_type: 'schedule', title: 'General membership', schedule_note: 'Third Tuesday, monthly', sort_order: 1 },
    { meeting_type: 'schedule', title: 'Executive board', schedule_note: 'First Monday, monthly', sort_order: 2 },
    { meeting_type: 'schedule', title: 'Health & safety committee', schedule_note: 'Second Wednesday, monthly', sort_order: 3 },
  ],
  documents: [
    { category: 'Agreement', title: 'Collective Agreement 2023–2026', meta: 'PDF · Agreement · 1.8 MB', storage_path: '#' },
    { category: 'Governance', title: 'Local 412 Bylaws', meta: 'PDF · Governance · 320 KB', storage_path: '#' },
    { category: 'Forms', title: 'Grievance Form', meta: 'PDF · Forms · 180 KB', storage_path: '#' },
    { category: 'Committees', title: 'Health & Safety — Meeting Minutes', meta: 'PDF · Committees · 240 KB', storage_path: '#' },
  ],
};

const html = renderSitePage(site);
const out = path.resolve(__dirname, '../../UX design/tier1-website-mockups/rendered-preview-local412.html');
fs.writeFileSync(out, html, 'utf8');
console.log(`Wrote ${html.length} bytes → ${out}`);
