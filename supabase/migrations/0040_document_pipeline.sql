-- =============================================================================
-- 0040_document_pipeline.sql · OCR & knowledge pipeline — the data model
-- =============================================================================
-- First migration of the document → verified knowledge pipeline (see
-- docs/OCR-KNOWLEDGE-PIPELINE.md). Two tables:
--   · source_documents      — one row per uploaded document (type, priority
--                             tier, storage path, pipeline status).
--   · document_extractions  — the AI (Claude-vision) output for a document:
--                             text + structured fields + a confidence score and
--                             bucket, gated behind a human VERIFY step.
--
-- The trust gate is enforced in the database, not just the app: a steward
-- (member) can only read an extraction once it is PUBLISHED (verified). So the
-- retrieval/RAG layer can never surface an unverified OCR result — a bad scan
-- can never become "your agreement says…". Admins manage the whole pipeline.
--
-- Depends on: 0001 (set_updated_at), 0002/0008 (get_request_tenant_id,
-- is_request_tenant_admin), 0022 (is_request_tenant_member). Storage bucket +
-- the extract-document edge function are the next steps, not this migration.
-- Idempotent. After applying: NOTIFY pgrst, 'reload schema';
-- =============================================================================

BEGIN;

-- ─── 1 · source_documents ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.source_documents (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,
  title             text        NOT NULL,
  doc_type          text        NOT NULL DEFAULT 'other'
                                  CHECK (doc_type IN ('cba','grievance','policy','minutes','bylaws','correspondence','other')),
  -- Work-backwards: 1 = current & active, 2 = recent, 3 = deep archive.
  priority_tier     int         NOT NULL DEFAULT 1 CHECK (priority_tier BETWEEN 1 AND 3),
  storage_path      text,                      -- Supabase Storage object path
  original_filename text,
  page_count        int,
  -- Pipeline lifecycle. RAG never touches anything but 'published'.
  status            text        NOT NULL DEFAULT 'uploaded'
                                  CHECK (status IN ('uploaded','extracting','extracted',
                                                    'in_review','needs_attention','verified',
                                                    'published','rejected')),
  uploaded_by       uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT NOW(),
  updated_at        timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT source_documents_title_not_blank CHECK (length(trim(title)) > 0)
);
CREATE INDEX IF NOT EXISTS idx_source_documents_tenant        ON public.source_documents (tenant_id);
CREATE INDEX IF NOT EXISTS idx_source_documents_tenant_status ON public.source_documents (tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_source_documents_tenant_tier   ON public.source_documents (tenant_id, priority_tier);

DROP TRIGGER IF EXISTS source_documents_set_updated_at ON public.source_documents;
CREATE TRIGGER source_documents_set_updated_at
  BEFORE UPDATE ON public.source_documents
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ─── 2 · document_extractions ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.document_extractions (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,
  document_id        uuid        NOT NULL REFERENCES public.source_documents(id) ON DELETE CASCADE,
  extracted_text     text,
  -- Typed to the document kind (e.g. a CBA article's number/title/body).
  structured         jsonb       NOT NULL DEFAULT '{}'::jsonb,
  -- Per-field confidence, e.g. {"article_number": 98, "body": 91}.
  field_confidence   jsonb       NOT NULL DEFAULT '{}'::jsonb,
  -- Overall score = min(model self-report, structural validation). 0–100.
  confidence         numeric(5,2) CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 100)),
  -- Derived triage bucket (set by the extract function; kept for fast queries).
  bucket             text        CHECK (bucket IN ('high','review','attention')),
  model              text,
  input_tokens       int,
  output_tokens      int,
  estimated_cost_usd numeric(10,5),
  -- The gate: only published extractions are retrievable by members / RAG.
  published          boolean     NOT NULL DEFAULT false,
  verified_by        uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  verified_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT NOW(),
  updated_at         timestamptz NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_document_extractions_tenant    ON public.document_extractions (tenant_id);
CREATE INDEX IF NOT EXISTS idx_document_extractions_document  ON public.document_extractions (document_id);
CREATE INDEX IF NOT EXISTS idx_document_extractions_bucket    ON public.document_extractions (tenant_id, bucket);
CREATE INDEX IF NOT EXISTS idx_document_extractions_published ON public.document_extractions (tenant_id) WHERE published;

DROP TRIGGER IF EXISTS document_extractions_set_updated_at ON public.document_extractions;
CREATE TRIGGER document_extractions_set_updated_at
  BEFORE UPDATE ON public.document_extractions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ─── 3 · RLS ────────────────────────────────────────────────────────────────
ALTER TABLE public.source_documents     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.source_documents     FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.document_extractions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_extractions FORCE  ROW LEVEL SECURITY;

-- source_documents · members (stewards/admins) of the tenant see the library;
-- admins manage it.
DROP POLICY IF EXISTS source_documents_member_read ON public.source_documents;
CREATE POLICY source_documents_member_read
  ON public.source_documents FOR SELECT TO authenticated
  USING (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_member());

DROP POLICY IF EXISTS source_documents_admin_write ON public.source_documents;
CREATE POLICY source_documents_admin_write
  ON public.source_documents FOR ALL TO authenticated
  USING      (public.is_request_tenant_admin() AND tenant_id = public.get_request_tenant_id())
  WITH CHECK (public.is_request_tenant_admin() AND tenant_id = public.get_request_tenant_id());

-- document_extractions · THE GATE. Members read only PUBLISHED extractions
-- (this is what RAG retrieves). Admins read all (to run the review queue) and
-- manage everything.
DROP POLICY IF EXISTS document_extractions_member_read_published ON public.document_extractions;
CREATE POLICY document_extractions_member_read_published
  ON public.document_extractions FOR SELECT TO authenticated
  USING (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_member() AND published);

DROP POLICY IF EXISTS document_extractions_admin_read ON public.document_extractions;
CREATE POLICY document_extractions_admin_read
  ON public.document_extractions FOR SELECT TO authenticated
  USING (public.is_request_tenant_admin() AND tenant_id = public.get_request_tenant_id());

DROP POLICY IF EXISTS document_extractions_admin_write ON public.document_extractions;
CREATE POLICY document_extractions_admin_write
  ON public.document_extractions FOR ALL TO authenticated
  USING      (public.is_request_tenant_admin() AND tenant_id = public.get_request_tenant_id())
  WITH CHECK (public.is_request_tenant_admin() AND tenant_id = public.get_request_tenant_id());

COMMENT ON TABLE public.source_documents IS
  'OCR/knowledge pipeline: one row per uploaded document. Work-backwards via '
  'priority_tier; lifecycle via status. RAG only ever reads published content.';
COMMENT ON TABLE public.document_extractions IS
  'AI (Claude-vision) extraction for a source_document: text + structured fields '
  '+ confidence/bucket. The published flag is the verify gate — members/RAG read '
  'only published rows; admins run the review queue over all rows.';
COMMENT ON COLUMN public.document_extractions.confidence IS
  'Overall 0–100 = min(model self-report, structural validation). Buckets: '
  'high ≥ 90, review 70–89, attention < 70.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- Next steps (separate units): a Supabase Storage bucket for source files;
-- the extract-document edge function (Claude vision → structured + confidence,
-- logs to ai_generations); the review/verify dashboard in the admin app; and
-- wiring published extractions into rag.ts retrieval with citations.
-- ════════════════════════════════════════════════════════════════════════════
