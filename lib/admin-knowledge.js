/* ──────────────────────────────────────────────────────────────────────────
   The Union Hub · lib/admin-knowledge.js
   Institutional-knowledge reads for the admin app — the "the Local never
   loses its memory" surface.

   Reads the STAGED grievance tier (grievance_cases + grievance_history +
   grievance_precedents) and steward knowledge (knowledge_entries) plus the
   collective agreement (cba_articles). Every query is tenant-scoped via the
   x-tenant-id header that lib/supabase.js attaches; RLS enforces isolation
   AND role, server-side — this module trusts none of its own filtering.

   RLS access (verified against migrations 0022–0041, NOT executed here):
     · grievance_cases / grievance_precedents / grievance_history
         USING (tenant_id = get_request_tenant_id() AND is_request_tenant_member())
       and is_request_tenant_member() = is_request_tenant_admin() OR steward,
       so a tenant admin (the admin persona) reads them all.
     · knowledge_entries
         USING (tenant_id = get_request_tenant_id()
                AND (user_id = auth.uid() OR is_request_tenant_admin()))
       so an admin reads the WHOLE Local's notes (not just their own).

   No new tables, no policy changes, no demo-only logic. Read-only. Mirrors the
   tenantClient() + raw() shape of lib/admin-grievances.js; reuses its
   verifyTenantAdmin() so the page gate is identical.
   ────────────────────────────────────────────────────────────────────────── */

import createClient from '/lib/supabase.js';
import { getTenant } from '/lib/tenant.js';
import { verifyTenantAdmin } from '/lib/admin-grievances.js';

export { verifyTenantAdmin };

/* Recognised grievance-case statuses (public.grievance_status enum, 0024). */
export const CASE_STATUSES = ['INTAKE', 'STEP_1', 'STEP_2', 'STEP_3', 'ARBITRATION', 'CLOSED'];

/* Common themes shown as one-tap searches on the knowledge page. Illustrative
   only — search is free-text over the real data, not limited to these. */
export const KNOWLEDGE_THEMES = [
  'Attendance', 'Accommodation', 'Vacation', 'Discipline',
  'Overtime', 'Seniority', 'Health & Safety', 'Scheduling',
];

async function tenantClient() {
  const tenant = await getTenant();
  if (!tenant) throw new Error('no_tenant_context');
  return { tenant, client: createClient({ tenantId: tenant.id }) };
}

async function getJson(client, path, tag) {
  const res = await client.raw(path);
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    const err = new Error(tag || 'read_failed');
    err.status = res.status;
    err.body = body;
    throw err;
  }
  return res.json();
}

/* PostgREST `ilike` uses `*` as the wildcard. We wrap the term in `*…*`; the
   term itself is URL-encoded, and characters that would break an or() list
   (comma, parens, star) are stripped so one bad keystroke can't corrupt the
   filter. Spaces are kept (encoded) so "attendance management" matches. */
function likeTerm(q) {
  const cleaned = String(q ?? '').trim().replace(/[(),*]/g, ' ').replace(/\s+/g, ' ').trim();
  return encodeURIComponent(cleaned);
}

/* ── Grievance cases (the rich, staged tier) ─────────────────────────────── */

const CASE_SELECT =
  'id,case_number,current_status,contract_article,description,date_incident,date_filed,created_at,member:members(full_name)';

/**
 * List grievance cases, optional free-text (case #, article, description) and
 * status filter. RLS-scoped + member-gated (admin qualifies).
 */
export async function listCases({ q = '', status = null, limit = 100 } = {}) {
  const { client } = await tenantClient();
  let path = `/rest/v1/grievance_cases?select=${CASE_SELECT}&order=date_filed.desc&limit=${limit}`;
  const term = likeTerm(q);
  if (term) path += `&or=(case_number.ilike.*${term}*,contract_article.ilike.*${term}*,description.ilike.*${term}*)`;
  if (status && CASE_STATUSES.includes(status)) path += `&current_status=eq.${status}`;
  return getJson(client, path, 'cases_failed');
}

/** One grievance case by id (RLS-scoped). Returns the row or null. */
export async function getCase(id) {
  const { client } = await tenantClient();
  const rows = await getJson(client, `/rest/v1/grievance_cases?select=${CASE_SELECT}&id=eq.${encodeURIComponent(id)}&limit=1`, 'case_failed');
  return Array.isArray(rows) ? (rows[0] || null) : null;
}

/** Status history (the step trail) for a case, oldest → newest. */
export async function getCaseHistory(caseId) {
  const { client } = await tenantClient();
  return getJson(client,
    `/rest/v1/grievance_history?select=id,from_status,to_status,notes,changed_at&grievance_id=eq.${encodeURIComponent(caseId)}&order=changed_at.asc`,
    'history_failed');
}

/** Precedents recorded on a case (resolution + lessons + linked article). */
export async function getCasePrecedents(caseId) {
  const { client } = await tenantClient();
  return getJson(client,
    `/rest/v1/grievance_precedents?select=id,resolution_summary,lessons_learned,created_at,article:cba_articles(article_number,title)&grievance_id=eq.${encodeURIComponent(caseId)}`,
    'precedents_failed');
}

/**
 * Related cases on the same collective-agreement article — the "how did we
 * handle this article before" list. Excludes the current case.
 */
export async function getRelatedCases(articleNumber, excludeId, limit = 12) {
  if (!articleNumber) return [];
  const { client } = await tenantClient();
  let path = `/rest/v1/grievance_cases?select=${CASE_SELECT}&contract_article=eq.${encodeURIComponent(articleNumber)}&order=date_filed.desc&limit=${limit}`;
  if (excludeId) path += `&id=neq.${encodeURIComponent(excludeId)}`;
  return getJson(client, path, 'related_failed');
}

/* ── Steward knowledge + collective agreement ────────────────────────────── */

const KNOWLEDGE_SELECT = 'id,title,issue_type,current_state,timeline,handoff_notes,updated_at';

/** Steward knowledge entries, optional free-text. Admin reads the whole Local. */
export async function listKnowledge({ q = '', limit = 100 } = {}) {
  const { client } = await tenantClient();
  let path = `/rest/v1/knowledge_entries?select=${KNOWLEDGE_SELECT}&order=updated_at.desc&limit=${limit}`;
  const term = likeTerm(q);
  if (term) path += `&or=(title.ilike.*${term}*,issue_type.ilike.*${term}*,current_state.ilike.*${term}*,timeline.ilike.*${term}*,handoff_notes.ilike.*${term}*)`;
  return getJson(client, path, 'knowledge_failed');
}

/** Collective-agreement articles, optional free-text over title/body. */
export async function listArticles({ q = '', limit = 60 } = {}) {
  const { client } = await tenantClient();
  let path = `/rest/v1/cba_articles?select=id,article_number,title,body&order=article_number.asc&limit=${limit}`;
  const term = likeTerm(q);
  if (term) path += `&or=(article_number.ilike.*${term}*,title.ilike.*${term}*,body.ilike.*${term}*)`;
  return getJson(client, path, 'articles_failed');
}

/**
 * The institutional-memory search. One free-text term fans out across the
 * cases, precedents, steward notes, and the agreement, and returns the four
 * result sets together so a search for "Attendance" surfaces the cluster.
 * Runs the four reads concurrently; each is independently RLS-scoped.
 */
export async function searchKnowledge(q) {
  const { client } = await tenantClient();
  const term = likeTerm(q);
  if (!term) return { cases: [], precedents: [], notes: [], articles: [] };

  const [cases, precedents, notes, articles] = await Promise.all([
    getJson(client, `/rest/v1/grievance_cases?select=${CASE_SELECT}&or=(case_number.ilike.*${term}*,contract_article.ilike.*${term}*,description.ilike.*${term}*)&order=date_filed.desc&limit=50`, 'cases_failed'),
    getJson(client, `/rest/v1/grievance_precedents?select=id,resolution_summary,lessons_learned,grievance_id,article:cba_articles(article_number,title)&or=(resolution_summary.ilike.*${term}*,lessons_learned.ilike.*${term}*)&limit=50`, 'precedents_failed'),
    getJson(client, `/rest/v1/knowledge_entries?select=${KNOWLEDGE_SELECT}&or=(title.ilike.*${term}*,issue_type.ilike.*${term}*,current_state.ilike.*${term}*,timeline.ilike.*${term}*,handoff_notes.ilike.*${term}*)&order=updated_at.desc&limit=50`, 'knowledge_failed'),
    getJson(client, `/rest/v1/cba_articles?select=id,article_number,title,body&or=(title.ilike.*${term}*,body.ilike.*${term}*)&order=article_number.asc&limit=20`, 'articles_failed'),
  ]);
  return { cases, precedents, notes, articles };
}

export default {
  CASE_STATUSES, KNOWLEDGE_THEMES, verifyTenantAdmin,
  listCases, getCase, getCaseHistory, getCasePrecedents, getRelatedCases,
  listKnowledge, listArticles, searchKnowledge,
};
