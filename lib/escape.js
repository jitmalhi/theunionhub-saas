/* ──────────────────────────────────────────────────────────────────────────
   lib/escape.js
   HTML-escape untrusted values before they go into innerHTML.

   card.html / verify.html build their DOM with template-literal innerHTML, and
   member fields (full_name, union_name, member_number, …) originate from
   admin/CSV input. With `script-src 'unsafe-inline'` in the CSP, an unescaped
   `<img onerror=…>` in a member name would execute on scan. Mirrors the `esc()`
   already used in access.html / admin/members.html — one shared copy now.
   ────────────────────────────────────────────────────────────────────────── */

const ENTITIES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

export function esc(value) {
  return String(value == null ? '' : value).replace(/[&<>"']/g, (c) => ENTITIES[c]);
}
