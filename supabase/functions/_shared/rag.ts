// Retrieval for grounding (RAG). Reads run through the CALLER's client, so RLS
// scopes everything to the caller's tenant — nothing cross-tenant is reachable.
// Retrieval-only: this data grounds the prompt; it is never used to train.

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export interface GrievanceCase {
  id: string;
  case_number: string | null;
  current_status: string | null;
  contract_article: string | null;
  description: string | null;
  date_incident: string | null;
  date_filed: string | null;
  [k: string]: unknown;
}

export interface CbaArticle {
  id: string;
  article_number: string;
  title: string;
  body: string | null;
}

export interface Precedent {
  article_id: string;
  resolution_summary: string;
  lessons_learned: string | null;
  created_at: string;
}

/** Split a free-text "contract_article" field like "14.08, 12.05" into numbers. */
function parseArticleNumbers(raw: string | null | undefined): string[] {
  if (!raw) return [];
  return raw
    .split(/[,;/]+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

export async function loadCase(
  db: SupabaseClient,
  caseId: string,
): Promise<GrievanceCase | null> {
  const { data, error } = await db
    .from("grievance_cases")
    .select("*")
    .eq("id", caseId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) throw error;
  return (data as GrievanceCase) ?? null;
}

export async function loadCbaArticles(
  db: SupabaseClient,
  articleNumbers: string[],
): Promise<CbaArticle[]> {
  if (!articleNumbers.length) return [];
  const { data, error } = await db
    .from("cba_articles")
    .select("id, article_number, title, body")
    .in("article_number", articleNumbers);
  if (error) throw error;
  return (data as CbaArticle[]) ?? [];
}

export async function loadPrecedents(
  db: SupabaseClient,
  articleIds: string[],
): Promise<Precedent[]> {
  if (!articleIds.length) return [];
  const { data, error } = await db
    .from("grievance_precedents")
    .select("article_id, resolution_summary, lessons_learned, created_at")
    .in("article_id", articleIds)
    .order("created_at", { ascending: false })
    .limit(20);
  if (error) throw error;
  return (data as Precedent[]) ?? [];
}

/** Assemble the case + CBA + precedents into a single cacheable grounding block. */
export async function buildGrounding(
  db: SupabaseClient,
  caseRow: GrievanceCase,
): Promise<{ text: string; articleIds: string[] }> {
  const numbers = parseArticleNumbers(caseRow.contract_article);
  const articles = await loadCbaArticles(db, numbers);
  const articleIds = articles.map((a) => a.id);
  const precedents = await loadPrecedents(db, articleIds);

  const lines: string[] = [];
  lines.push("=== COLLECTIVE AGREEMENT (cited articles) ===");
  if (articles.length) {
    for (const a of articles) {
      lines.push(`Article ${a.article_number} — ${a.title}`);
      if (a.body) lines.push(a.body);
      lines.push("");
    }
  } else {
    lines.push("(no matching articles found for this case)");
  }

  lines.push("=== PRIOR PRECEDENTS IN THIS LOCAL (same articles) ===");
  if (precedents.length) {
    for (const p of precedents) {
      lines.push(`- Outcome: ${p.resolution_summary}`);
      if (p.lessons_learned) lines.push(`  Lesson: ${p.lessons_learned}`);
    }
  } else {
    lines.push("(no prior precedents recorded for these articles)");
  }

  return { text: lines.join("\n"), articleIds };
}
