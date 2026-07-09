/* ──────────────────────────────────────────────────────────────────────────
   lib/verdict.js
   ONE source of verdict truth for /card and /verify.

   Harvested from member-id-system's verdictFor() and refactored so the card
   badge and the full-screen verify result derive from the same decision — no
   two pages disagreeing about what "active" vs "suspended" vs "not found"
   means.

   No new status values are introduced (decision D1). The live members.status
   vocabulary is: active | inactive | suspended | pending (0002 CHECK), plus the
   null-row "not found" case when lookup_member returns nothing.

   Distinct copy for the two failure modes is deliberate (harvested):
     · NOT VALID (lapsed) — the member IS on record, just not in good standing.
     · NOT FOUND          — nothing resolves to this id at all.
   Conflating them is the bug the scaffold fixed; keep them separate.
   ────────────────────────────────────────────────────────────────────────── */

import { esc } from '/lib/escape.js';

export const VERIFIED  = 'verified';
export const NOT_VALID = 'not_valid';
export const NOT_FOUND = 'not_found';

function titleCase(s) {
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : '';
}

/**
 * Derive the canonical verdict for a member row (or null → not found).
 * @param {object|null} member  a lookup_member row, or null/undefined.
 * @returns {{
 *   kind: string, valid: boolean, status: string,
 *   badge: { cls: 'active'|'inactive'|'suspended', label: string },
 *   cardState: 'active'|'inactive'|'suspended'|'notfound',
 *   word: string, reason: string, detail: string
 * }}
 */
export function verdictFor(member) {
  if (!member) {
    return {
      kind: NOT_FOUND, valid: false, status: '',
      badge: { cls: 'inactive', label: 'Not found' },
      cardState: 'notfound',
      word: 'Not found',
      reason: 'no-match',
      // Distinct from "lapsed": this id resolves to nothing at all.
      detail: 'No membership matches this code. It may be mistyped, revoked, or issued by another local.',
    };
  }

  const status = String(member.status || '').toLowerCase();

  if (status === 'active') {
    return {
      kind: VERIFIED, valid: true, status,
      badge: { cls: 'active', label: 'Active Member' },
      cardState: 'active',
      word: 'Verified',
      reason: 'ok',
      detail: '',
    };
  }

  if (status === 'suspended') {
    return {
      kind: NOT_VALID, valid: false, status,
      badge: { cls: 'suspended', label: 'Suspended' },
      cardState: 'suspended',
      word: 'Not valid',
      reason: 'Suspended',
      detail: 'This membership has been suspended. Contact your union administrator.',
    };
  }

  // inactive | pending | any other non-active known status → lapsed standing.
  // (Note: 'pending' previously rendered as NOT FOUND on the card — a latent
  // bug; it now correctly reads as on-record-but-not-in-good-standing.)
  return {
    kind: NOT_VALID, valid: false, status,
    badge: { cls: 'inactive', label: titleCase(status) || 'Inactive' },
    cardState: 'inactive',
    word: 'Not valid',
    reason: titleCase(status) || 'Inactive',
    // Distinct from "not found": the member is on record, just not active.
    detail: 'This membership is on record but not currently in good standing. Ask the member to check with their local.',
  };
}

/**
 * Reusable status-badge markup (StatusBadge harvested into the static stack).
 * Uses the .badge / .badge.active|inactive|suspended classes card.html defines.
 */
export function badgeHtml(verdict) {
  // badge.cls is a fixed enum (active|inactive|suspended); badge.label can be
  // titleCase(member.status), so escape it before it hits innerHTML.
  return `<div class="badge ${verdict.badge.cls}" role="status">`
    + `<span class="dot"></span>${esc(verdict.badge.label)}</div>`;
}
