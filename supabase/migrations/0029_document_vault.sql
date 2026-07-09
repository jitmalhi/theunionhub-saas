-- ════════════════════════════════════════════════════════════════════════
-- The Union Hub · Migration 0029 — document vault
-- ════════════════════════════════════════════════════════════════════════
-- Ports grievance-system 0008_document_vault onto the LIVE tenancy/role
-- model. Tenant-isolated document metadata (public.documents) + a PRIVATE
-- Supabase Storage bucket `union-docs` whose objects are laid out as
-- <tenant_id>/<filename>. Three pieces:
--
--   1. document_category enum ('AGREEMENT', 'LOU', 'ARBITRATION').
--   2. public.documents metadata table (bytes live in the bucket;
--      storage_path is the object path inside it).
--   3. Storage bucket `union-docs` (PRIVATE) + storage.objects policies
--      that gate access by the request tenant (first path folder) AND
--      membership of that tenant.
--
-- Reconciliation onto the live model (grievance-system → this app):
--   · current_tenant_id()          → get_request_tenant_id()  (0002)
--   · grievance role fns           → is_request_tenant_admin() (0008) /
--                                     is_request_tenant_member() (0022)
--   · steward_profiles/steward_role/current_tenant_id are NOT referenced.
--   · The header SELECTS the tenant; the database (membership) DECIDES.
--     A user who spoofs another tenant's header has no membership row and
--     is denied by is_request_tenant_member(). Reads require membership;
--     writes require admin.
--
-- Depends on: 0001 (tenants), 0002 (get_request_tenant_id),
--             0008 (is_request_tenant_admin), 0022 (is_request_tenant_member).
-- Replaces (discarded from grievance-system): current_tenant_id() and its
--          documents_isolation policy's for-all model.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ─── 1 · Document category enum ────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'document_category') THEN
    CREATE TYPE public.document_category AS ENUM ('AGREEMENT', 'LOU', 'ARBITRATION');
  END IF;
END$$;


-- ─── 2 · documents (metadata) ──────────────────────────────────────────
-- The bytes live in the union-docs storage bucket. storage_path is the
-- object path inside the bucket, by convention:
--   <tenant_id>/<filename>   (the leading folder is what storage RLS checks).
CREATE TABLE IF NOT EXISTS public.documents (
  id           uuid                      PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL      REFERENCES public.tenants(id) ON DELETE CASCADE
                                           DEFAULT public.get_request_tenant_id(),
  filename     text        NOT NULL,
  file_type    text,
  storage_path text        NOT NULL,
  category     public.document_category NOT NULL,
  uploaded_by  uuid                      REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL      DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_documents_tenant   ON public.documents (tenant_id);
CREATE INDEX IF NOT EXISTS idx_documents_category ON public.documents (tenant_id, category);


-- ─── 3 · RLS on public.documents ───────────────────────────────────────
-- Read: any member of the header tenant. Write: admins of the header
-- tenant only. Matches the grievance-table idiom established in 0022.
ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.documents FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS documents_select ON public.documents;
CREATE POLICY documents_select ON public.documents
  FOR SELECT TO authenticated
  USING (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_member());

DROP POLICY IF EXISTS documents_write ON public.documents;
CREATE POLICY documents_write ON public.documents
  FOR ALL TO authenticated
  USING      (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_admin())
  WITH CHECK (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_admin());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.documents TO authenticated;


-- ─── 4 · Storage bucket: union-docs (PRIVATE) ──────────────────────────
-- Idempotent insert. The bucket stays PRIVATE: agreements, LOUs and
-- arbitration decisions are tenant-confidential, so every fetch goes
-- through an authenticated, RLS-checked request (no /object/public/ URLs).
INSERT INTO storage.buckets (id, name, public)
VALUES ('union-docs', 'union-docs', false)
ON CONFLICT (id) DO UPDATE
  SET public = EXCLUDED.public;


-- ─── 5 · Storage RLS policies ──────────────────────────────────────────
-- storage.objects already has RLS enabled by Supabase. We add four policies
-- scoped to bucket_id = 'union-docs'.
--
-- Reconciled from grievance-system's current_tenant_id() path check onto
-- the live model: the object's first path folder must equal the REQUEST
-- tenant (get_request_tenant_id), AND the caller must be a member of that
-- tenant (is_request_tenant_member). Reads and writes both require
-- membership — this is a private, confidential vault, so there is no
-- anon/public read like the tenant-assets logo bucket (0011).
--
-- The CASE guard mirrors 0011: it prevents the ::text comparison from
-- ever seeing a non-tenant path, and get_request_tenant_id() being NULL
-- (no header) makes every comparison fail closed.

DROP POLICY IF EXISTS union_docs_member_read ON storage.objects;
CREATE POLICY union_docs_member_read
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'union-docs'
    AND (storage.foldername(name))[1] = public.get_request_tenant_id()::text
    AND public.is_request_tenant_member()
  );

DROP POLICY IF EXISTS union_docs_member_insert ON storage.objects;
CREATE POLICY union_docs_member_insert
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'union-docs'
    AND (storage.foldername(name))[1] = public.get_request_tenant_id()::text
    AND public.is_request_tenant_member()
  );

DROP POLICY IF EXISTS union_docs_member_update ON storage.objects;
CREATE POLICY union_docs_member_update
  ON storage.objects
  FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'union-docs'
    AND (storage.foldername(name))[1] = public.get_request_tenant_id()::text
    AND public.is_request_tenant_member()
  )
  WITH CHECK (
    bucket_id = 'union-docs'
    AND (storage.foldername(name))[1] = public.get_request_tenant_id()::text
    AND public.is_request_tenant_member()
  );

DROP POLICY IF EXISTS union_docs_member_delete ON storage.objects;
CREATE POLICY union_docs_member_delete
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'union-docs'
    AND (storage.foldername(name))[1] = public.get_request_tenant_id()::text
    AND public.is_request_tenant_member()
  );


COMMIT;

-- ════════════════════════════════════════════════════════════════════════
-- Post-migration verification:
--
--   -- Enum + table exist:
--   SELECT enumlabel FROM pg_enum
--     JOIN pg_type t ON t.oid = enumtypid
--    WHERE t.typname = 'document_category' ORDER BY enumsortorder;
--   SELECT relrowsecurity, relforcerowsecurity FROM pg_class
--    WHERE oid = 'public.documents'::regclass;
--
--   -- Private bucket exists:
--   SELECT id, public FROM storage.buckets WHERE id = 'union-docs';
--
--   -- Four storage policies scoped to the bucket:
--   SELECT polname FROM pg_policy
--    WHERE polrelid = 'storage.objects'::regclass
--      AND polname LIKE 'union_docs_%' ORDER BY polname;
-- ════════════════════════════════════════════════════════════════════════

-- After applying: NOTIFY pgrst, 'reload schema';
