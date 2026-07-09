-- =============================================================================
-- document_pipeline_isolation_test.sql
-- Proves the 0040 guarantees — most importantly THE VERIFY GATE at the database:
--
--   (1) A member (steward) reads ONLY published extractions — an unpublished
--       (unverified) OCR result is invisible to retrieval/RAG.
--   (2) An admin reads ALL extractions (to run the review queue).
--   (3) Cross-tenant: a member of tenant A sees nothing of tenant B.
--   (4) A member cannot write to the pipeline (admin-only).
--
-- Run against a DB with migrations 0001–0040 applied (supabase db reset then
-- psql -f, or the SQL editor). Self-contained; rolls back.
-- =============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.as_auth(p_user uuid, p_tenant uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-tenant-id', p_tenant)::text, true);
END $$;

DO $$
DECLARE
  v_a      uuid;
  v_b      uuid;
  v_admin  uuid := gen_random_uuid();
  v_member uuid := gen_random_uuid();
  v_doc    uuid := gen_random_uuid();
  v_cnt    integer;
BEGIN
  -- ─── Setup (superuser) ────────────────────────────────────────────────────
  INSERT INTO public.tenants (slug, display_name, contact_email)
    VALUES ('iso-dp-a-' || substr(v_admin::text,1,8), 'Iso DP A', 'a@test.local') RETURNING id INTO v_a;
  INSERT INTO public.tenants (slug, display_name, contact_email)
    VALUES ('iso-dp-b-' || substr(v_admin::text,1,8), 'Iso DP B', 'b@test.local') RETURNING id INTO v_b;

  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at) VALUES
    (v_admin,  '00000000-0000-0000-0000-000000000000','authenticated','authenticated','adm-'||substr(v_admin::text,1,8)||'@test.local', now(), now()),
    (v_member, '00000000-0000-0000-0000-000000000000','authenticated','authenticated','mem-'||substr(v_member::text,1,8)||'@test.local', now(), now());

  -- admin of B; steward (member) of B
  INSERT INTO public.tenant_admins (tenant_id, user_id) VALUES (v_b, v_admin);
  INSERT INTO public.stewards (tenant_id, user_id, full_name) VALUES (v_b, v_member, 'Iso DP Member');

  -- one document in B with a published + an unpublished extraction
  INSERT INTO public.source_documents (id, tenant_id, title, doc_type, status)
    VALUES (v_doc, v_b, 'Iso CBA', 'cba', 'published');
  INSERT INTO public.document_extractions (tenant_id, document_id, extracted_text, confidence, bucket, published) VALUES
    (v_b, v_doc, 'verified & published text', 95, 'high',       true),
    (v_b, v_doc, 'draft, not yet verified',   60, 'attention',  false);

  -- (1) member of B sees ONLY the published extraction ─ THE GATE
  PERFORM pg_temp.as_auth(v_member, v_b);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO v_cnt FROM public.document_extractions;
  ASSERT v_cnt = 1, 'FAIL: member saw ' || v_cnt || ' extractions (should be 1 — published only)';

  -- (2) admin of B sees BOTH
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.as_auth(v_admin, v_b);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO v_cnt FROM public.document_extractions;
  ASSERT v_cnt = 2, 'FAIL: admin saw ' || v_cnt || ' extractions (should be 2)';

  -- (3) member with tenant A's header (not a member of A) sees nothing
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.as_auth(v_member, v_a);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO v_cnt FROM public.document_extractions;
  ASSERT v_cnt = 0, 'FAIL: cross-tenant extraction read returned ' || v_cnt;
  SELECT count(*) INTO v_cnt FROM public.source_documents;
  ASSERT v_cnt = 0, 'FAIL: cross-tenant source_documents read returned ' || v_cnt;

  -- (4) member cannot write to the pipeline (admin-only)
  BEGIN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.as_auth(v_member, v_b);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO public.source_documents (tenant_id, title) VALUES (v_b, 'member insert attempt');
    RAISE EXCEPTION 'FAIL: member was able to INSERT a source_document';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;  -- RLS blocked the write (no member write policy) — expected
  END;

  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS: verify gate holds — members read published only, admins read all, cross-tenant denied, member writes blocked.';
END $$;

ROLLBACK;
