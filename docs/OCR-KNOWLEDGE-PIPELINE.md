# OCR & Knowledge Pipeline — design

**One line:** turn a local's paper/PDF documents into a **verified, searchable institutional memory** — value-first, human-confirmed, and grounded so the AI only ever answers from documents the local has actually verified.

This is not "scan and archive." Archiving stores a PDF you still have to go read. This stores **answers** — a steward asks *"what does our agreement say about overtime on a stat holiday, and have we grieved it before?"* and gets a grounded answer with citations, from the local's own documents.

It fits the locked architecture: **one Supabase, one deployment, one AI provider (Anthropic).** No new vendor — the "OCR" is Claude's vision reading the page, which also structures it in the same step. It plugs into the knowledge/RAG layer that already exists (`knowledge_entries` 0018, `cba_articles`/`grievance_precedents` 0025, `document_vault` 0029, `rag.ts`, `ai_generations` 0030).

---

## The five principles (these are the pitch)

1. **Value-first — work backwards.** Don't start at the oldest box in the basement. Start with what the local *needs retrievable today*: the in-force collective agreement, open and recent grievances, active policies, recent settlements. The 1974 minutes wait their turn. The local gets value in **week one**, not year three.
2. **Verify before it counts.** AI *proposes*; a human *confirms*. Only **verified** content is ever retrievable. Unverified OCR never reaches an answer — so the system can never tell a steward "our policy says X" from a bad scan.
3. **Confidence is visible.** Every document is scored. The local always sees: how many came through clean (**≥ 90%**), how many are in review, and how many **need serious attention**. No black box.
4. **Retrieval, not archiving.** The deliverable is questions answered with citations — grounded in the local's *own* verified documents.
5. **Inside the existing stack.** Supabase for storage + data + RLS; Anthropic (already integrated in `ai-service`) for vision extraction and retrieval. Nothing new to run.

---

## The pipeline (six stages)

```
  UPLOAD ─▶ EXTRACT ─▶ TRIAGE ─▶ VERIFY ─▶ PUBLISH ─▶ RETRIEVE
 (storage) (Claude    (confidence (human   (into the   (AI answers,
           vision)     buckets)   confirms) knowledge   grounded +
                                            base)       cited)
                                   │
                          ┌────────┴─────────┐
                     ≥90% ready        <threshold →
                     to confirm        "needs attention"
```

1. **Upload.** Scanned pages / PDFs / exports land in Supabase Storage (tenant-scoped bucket). A `source_documents` row is created with a **document type** (cba · grievance · policy · minutes · bylaws · correspondence) and a **priority tier** (see work-backwards).
2. **Extract.** An edge function (an extension of `ai-service`) sends the page image(s) to **Claude vision**, which returns (a) clean text and (b) **structured fields** typed to the document kind — e.g. a CBA article's number/title/body, a grievance's parties/dates/step/outcome. One step does OCR *and* structuring, because the model understands what it's reading.
3. **Triage — confidence.** Each document gets a **confidence score** (below). It routes automatically: **≥ 90% → ready to confirm** (a fast human glance), **70–89% → review**, **< 70% → needs serious attention** (bad scan, handwriting, missing pages). The dashboard shows the counts.
4. **Verify (human-in-the-loop).** A person (admin/steward) sees the extraction next to the page, fixes anything, and marks it **verified**. This is the trust gate and it's non-negotiable.
5. **Publish.** On verify, the content is pushed into the **knowledge base** (`knowledge_entries` / `cba_articles` / `grievance_precedents`) with status **published**. *Only published content is retrievable.*
6. **Retrieve.** `rag.ts` / `ai-service` grounds every answer and every AI grievance draft in the local's **published** knowledge — with citations back to the source document.

---

## Confidence — how the number is real (not vibes)

A defensible score, not just "the model felt good":

```
confidence = min( model_self_report , structural_validation )
```

- **model_self_report** — Claude returns a 0–100 confidence per field and per document (it's good at flagging its own uncertainty on smudged text, handwriting, cut-off pages).
- **structural_validation** — deterministic checks the code runs on the extracted data: do dates parse? are required fields present for this document type? does a member/article number match the expected format? is any page blank/garbled? Each failure pulls the score down.

Taking the **min** means a document only scores high when the model is confident **and** the data actually holds together. Buckets drive the dashboard:

| Bucket | Score | What it means | Where it goes |
|---|---|---|---|
| 🟢 High | ≥ 90 | Clean extraction, data validates | Quick confirm queue |
| 🟡 Review | 70–89 | Mostly good, worth a look | Review queue |
| 🔴 Needs attention | < 70 | Bad scan / handwriting / gaps | Priority human queue |

**The dashboard the local sees:** *"142 documents · 118 ready (≥90%) · 16 in review · 8 need attention"* — per priority tier, with progress bars. That's the "clear understanding of how many are 90%+ or need serious attention" you asked for.

---

## Work backwards — the digitization playbook

Digitize by **importance and recency**, not chronology. Encoded as `priority_tier`:

- **Tier 1 — Current & active** *(do first, fully)*: the in-force collective agreement, open grievances, active policies/LOUs, settlements from the last ~2 years. This is what makes the system *useful the first week*.
- **Tier 2 — Recent history**: grievances and correspondence from the last ~5 years — the precedent a steward actually cites.
- **Tier 3 — Deep archive**: everything older, the basement boxes. Real historical value, lowest urgency — digitized as budget/time allows (and where a cheaper bulk OCR engine can be added later if volume warrants).

**Why this sells:** the local sees their current agreement searchable in days, while the archive fills in behind it. Progress is visible per tier, so "we're 100% on Tier 1, 40% on Tier 2" is a concrete status, not "we're somewhere in the 90s."

---

## Data model (proposed — migration `0040`+)

Two new tables; everything downstream reuses the **existing** knowledge tables so this isn't a separate silo.

- **`source_documents`** — one row per uploaded document: `tenant_id`, `title`, `doc_type` (check-constrained), `priority_tier` (1–3), `storage_path`, `original_filename`, `page_count`, `status` (`uploaded` → `extracting` → `extracted` → `in_review` → `needs_attention` → `verified` → `published` / `rejected`), `uploaded_by`, timestamps.
- **`document_extractions`** — the AI output: `document_id`, `extracted_text`, `structured` (jsonb, typed to `doc_type`), `field_confidence` (jsonb map), `confidence` (numeric 0–100), `bucket` (high/review/attention), `model`, `tokens`, `estimated_cost_usd`, `verified_by`, `verified_at`.
- **Publish target:** verified extractions write into `knowledge_entries` / `cba_articles` / `grievance_precedents` (already exist) with a `published` flag + a `source_document_id` back-reference (a citation).
- **RLS:** tenant-scoped like every table; writes require admin/steward membership; **RAG reads only `published` rows**. The review queue is just `source_documents WHERE status IN ('in_review','needs_attention')`.
- **Cost:** each extraction logs to `ai_generations` (0030) — per-tenant cost tracking already exists, and work-backwards keeps early spend low (few, high-value docs).

---

## The verify gate — why it's the whole trust story

The single most important design decision, and the strongest thing to sell: **the AI can only ever retrieve from documents a human verified.** An OCR mistake on a scanned page can *never* become "your agreement says…" in an answer, because unverified content isn't in the retrievable set. For a union — where being wrong about the CBA or a precedent has real consequences — that guardrail is the product, not a footnote. Pair it with citations (every answer links its source document) and a steward can always check the original.

---

## Honest phasing (what you sell vs. what you build)

- **Phase 1 — concierge + verify (buildable now, on today's stack).** You (AI-assisted) upload and extract with Claude vision, the confidence dashboard triages, you verify, published content becomes retrievable. Sold truthfully as a **document-onboarding service** you deliver — the automation does the heavy lifting, a human confirms. This is real today; nothing new to procure.
- **Phase 2 — self-serve + dashboard UI.** Locals upload their own; the confidence dashboard and review queue become a screen in the admin app; richer per-field extraction and correction.
- **Phase 3 — scale the archive.** For high-volume Tier-3 digitization, add a dedicated bulk OCR pass (only if volume justifies a second tool) feeding the same verify gate.

**What's honest to say to a local today:** *"We digitize your documents with AI, you verify them, and then your union can search and ask questions of its own records — and the AI will never answer from anything you haven't confirmed."* Every word of that is deliverable on the current stack.

---

## Build order (when you're ready)
1. `0040` schema (`source_documents`, `document_extractions`) + RLS + the `published` flag/back-reference on the knowledge tables + isolation test.
2. `extract-document` edge function (Claude vision → structured + confidence), logging to `ai_generations`.
3. The verify/triage screen in the admin app (reuses the Phase-2 admin patterns) — the confidence dashboard + review queue + confirm action.
4. Wire published knowledge into `rag.ts` retrieval with citations.

_Prepared as a design. Buildable on Supabase + Anthropic with no new vendor. Say the word and I'll start at step 1._
