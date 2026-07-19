-- ════════════════════════════════════════════════════════════════════════
-- demo_seed.sql — "Demo – Local 79" demonstration tenant
-- ════════════════════════════════════════════════════════════════════════
-- A FIRST-CLASS TENANT, not a special mode. Uses ONLY the existing production
-- schema — no new tables, no demo flags, no bypasses. Everything here is
-- reachable through the same RLS/auth/workflows a real customer uses.
--
-- FICTIONAL. "Demo – Local 79" is a fictional municipal/public-sector local
-- modelled on a familiar structure. No real members, grievances, executive
-- discussions, investigations, arbitration records, or confidential data.
-- Employers appear only as TEXT inside content (no employer table exists).
-- Voting is a ROADMAP item (a post says so) — no voting tables/records exist.
--
-- IDEMPOTENT + TENANT-SCOPED: resolves the demo tenant by slug, deletes and
-- reloads ONLY rows WHERE tenant_id = <demo id>. It never reads or writes any
-- other tenant's rows. Run it against the database where the demo tenant lives:
--   npx --no-install supabase db query --db-url "<url>" -f supabase/demo/demo_seed.sql
-- (Run as a role that bypasses RLS — postgres/service_role — like any seed.)
--
-- Does NOT touch migration 0041, the isolation suite, or production customer data.
-- ════════════════════════════════════════════════════════════════════════

-- Fixed, clearly-demo UUIDs so re-runs are idempotent and cross-references hold.
-- Members:  d0de0000-…-00000000000N   Steward logins: d0de0001-…   Stewards: d0de0002-…

INSERT INTO public.tenants (slug, display_name, local_number, union_type, accent_hex, contact_email, status)
VALUES ('demo', 'Demo – Local 79', '79', 'Municipal / Public Sector', '#2F5D7C', 'demo@theunionhub.ca', 'active')
ON CONFLICT (slug) DO UPDATE
  SET display_name = EXCLUDED.display_name, local_number = EXCLUDED.local_number,
      union_type = EXCLUDED.union_type, accent_hex = EXCLUDED.accent_hex, status = EXCLUDED.status;

DO $$
DECLARE
  t uuid;
  -- steward login accounts (auth.users) — fictional; the demo admin signs in via
  -- the tenant contact_email bootstrap, NOT these. These exist so stewards can be
  -- assigned to grievances (grievance_cases.assigned_to → auth.users).
  su1 uuid := 'd0de0001-0000-4000-8000-000000000001'; -- Chief Steward login
  su2 uuid := 'd0de0001-0000-4000-8000-000000000002';
  su3 uuid := 'd0de0001-0000-4000-8000-000000000003';
BEGIN
  SELECT id INTO t FROM public.tenants WHERE slug = 'demo';
  IF t IS NULL THEN RAISE EXCEPTION '[demo-seed] demo tenant missing'; END IF;

  -- ── clean (scoped to the demo tenant only) ──────────────────────────────
  DELETE FROM public.grievance_cases WHERE tenant_id = t;   -- cascades grievance_history
  DELETE FROM public.documents       WHERE tenant_id = t;
  DELETE FROM public.cba_articles    WHERE tenant_id = t;
  DELETE FROM public.stewards        WHERE tenant_id = t;
  DELETE FROM public.members         WHERE tenant_id = t;
  DELETE FROM public.site_alerts     WHERE tenant_id = t;
  DELETE FROM public.site_posts      WHERE tenant_id = t;
  DELETE FROM public.site_officers   WHERE tenant_id = t;
  DELETE FROM public.site_stewards   WHERE tenant_id = t;
  DELETE FROM public.site_meetings   WHERE tenant_id = t;

  -- ── steward login accounts (fictional emails; never receive mail) ────────
  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at) VALUES
    (su1,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','chief.steward@local79.demo', now(), now()),
    (su2,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','steward.pw@local79.demo',    now(), now()),
    (su3,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','steward.parks@local79.demo', now(), now())
  ON CONFLICT (id) DO NOTHING;

  -- ── members (fictional, varied; departments = bargaining units) ─────────
  INSERT INTO public.members (id, tenant_id, full_name, first_name, last_name, status, membership_status,
                              email, job_classification, department, location, seniority_date) VALUES
   ('d0de0000-0000-4000-8000-000000000001', t,'Adaeze Obi','Adaeze','Obi','active','ACTIVE','aobi@example.com','Heavy Equipment Operator','Public Works','Riverbend Yards','2009-05-11'),
   ('d0de0000-0000-4000-8000-000000000002', t,'Liam Fournier','Liam','Fournier','active','ACTIVE','lfournier@example.com','Water Treatment Operator','Water & Wastewater','Riverbend WTP','2013-09-02'),
   ('d0de0000-0000-4000-8000-000000000003', t,'Priya Nair','Priya','Nair','active','ACTIVE','pnair@example.com','Library Technician','Library','Central Branch','2016-01-18'),
   ('d0de0000-0000-4000-8000-000000000004', t,'Marcus Delgado','Marcus','Delgado','active','ACTIVE','mdelgado@example.com','Parks Maintenance','Parks & Recreation','Lakeshore Park','2007-06-25'),
   ('d0de0000-0000-4000-8000-000000000005', t,'Sarah Whitecloud','Sarah','Whitecloud','active','ACTIVE','swhitecloud@example.com','Administrative Clerk II','Clerical & Administrative','City Hall','2019-03-04'),
   ('d0de0000-0000-4000-8000-000000000006', t,'Tomasz Kowalski','Tomasz','Kowalski','active','ACTIVE','tkowalski@example.com','Transit Operator','Transit','Riverbend Transit','2011-11-14'),
   ('d0de0000-0000-4000-8000-000000000007', t,'Fatima Rahman','Fatima','Rahman','active','ACTIVE','frahman@example.com','Social Services Worker','Community & Social Services','Community Centre','2014-08-19'),
   ('d0de0000-0000-4000-8000-000000000008', t,'Grace Okonkwo','Grace','Okonkwo','active','ACTIVE','gokonkwo@example.com','By-law Enforcement Officer','By-law Enforcement','City Hall','2018-02-27'),
   ('d0de0000-0000-4000-8000-000000000009', t,'Daniel Petrov','Daniel','Petrov','inactive','INACTIVE','dpetrov@example.com','Labourer','Public Works','Riverbend Yards','2021-07-06'),
   ('d0de0000-0000-4000-8000-000000000010', t,'Chloe Tremblay','Chloe','Tremblay','active','ACTIVE','ctremblay@example.com','Recreation Programmer','Parks & Recreation','Aquatic Centre','2020-10-12');

  -- ── stewards (Chief + unit stewards; some with login, one pre-created) ──
  INSERT INTO public.stewards (id, tenant_id, user_id, full_name, title, email, worksite, status) VALUES
   ('d0de0002-0000-4000-8000-000000000001', t, su1,  'Adaeze Obi','Chief Steward','chief.steward@local79.demo','All units','active'),
   ('d0de0002-0000-4000-8000-000000000002', t, su2,  'Liam Fournier','Unit Steward','steward.pw@local79.demo','Public Works / Water','active'),
   ('d0de0002-0000-4000-8000-000000000003', t, su3,  'Marcus Delgado','Unit Steward','steward.parks@local79.demo','Parks & Recreation','active'),
   ('d0de0002-0000-4000-8000-000000000004', t, NULL, 'Priya Nair','Unit Steward','pnair@example.com','Library / Clerical','active'),
   ('d0de0002-0000-4000-8000-000000000005', t, NULL, 'Fatima Rahman','Unit Steward','frahman@example.com','Community & Social Services','active');

  -- ── collective agreement articles (fictional Riverbend Municipal CA 2024–2027) ─
  INSERT INTO public.cba_articles (tenant_id, article_number, title, body) VALUES
   (t,'Article 6','Hours of Work','Standard work week and scheduling for full-time and part-time employees of the City of Riverbend.'),
   (t,'Article 9','Seniority','Definition, accrual, and application of seniority in layoffs, recalls, and job postings.'),
   (t,'Article 12','Overtime Distribution','Overtime shall be offered on an equalized basis by seniority within the classification and department.'),
   (t,'Article 15','Health & Safety','Joint Health & Safety Committee, right to refuse unsafe work, and provision of protective equipment.'),
   (t,'Article 19','Job Postings','Vacancies posted for seven (7) calendar days; awarded on qualifications and seniority.'),
   (t,'Article 30','Discipline & Discharge','Progressive discipline, just cause, and the employee''s right to representation.');

  -- ── grievances (full lifecycle incl. an arbitration and a closed case) ──
  -- Employers referenced as TEXT only. assigned_to = a steward login.
  INSERT INTO public.grievance_cases (tenant_id, member_id, case_number, current_status, date_incident, date_filed, contract_article, description, assigned_to) VALUES
   (t,'d0de0000-0000-4000-8000-000000000002','GRV-2026-0031','STEP_2','2026-05-20','2026-05-26','Article 12','Overtime at the Riverbend Water Treatment Plant was assigned out of seniority order; grievor was skipped for a weekend call-in. City of Riverbend denied at Step 1.', su2),
   (t,'d0de0000-0000-4000-8000-000000000001','GRV-2026-0028','STEP_1','2026-06-02','2026-06-05','Article 15','Public Works crew directed to operate equipment without required guarding; health & safety concern raised with the City of Riverbend.', su2),
   (t,'d0de0000-0000-4000-8000-000000000004','GRV-2026-0019','ARBITRATION','2025-11-10','2025-11-17','Article 30','Discharge of a Parks & Recreation employee; Union asserts absence of just cause. Referred to arbitration after Step 3 denial by the City of Riverbend.', su3),
   (t,'d0de0000-0000-4000-8000-000000000003','GRV-2026-0022','STEP_3','2026-04-08','2026-04-14','Article 19','Library Technician posting awarded to a junior applicant; grievor has greater seniority and equal qualifications (Riverbend Public Library Board).', su1),
   (t,'d0de0000-0000-4000-8000-000000000008','GRV-2026-0035','INTAKE','2026-07-09','2026-07-14','Article 6','Repeated short-notice schedule changes for By-law Enforcement contrary to the hours-of-work provisions.', su1),
   (t,'d0de0000-0000-4000-8000-000000000006','GRV-2025-0104','CLOSED','2025-08-01','2025-08-06','Article 9','Transit Operator recall order; resolved in the Union''s favour at Step 2 — grievor reinstated to the schedule by seniority.', su1);

  -- ── documents (fictional; storage paths are placeholders) ───────────────
  INSERT INTO public.documents (tenant_id, filename, file_type, storage_path) VALUES
   (t,'Riverbend-Municipal-Collective-Agreement-2024-2027.pdf','application/pdf','demo/ca-2024-2027.pdf'),
   (t,'Local-79-Bylaws.pdf','application/pdf','demo/local79-bylaws.pdf'),
   (t,'Grievance-Form.pdf','application/pdf','demo/grievance-form.pdf'),
   (t,'Health-Safety-Committee-Minutes-2026-06.pdf','application/pdf','demo/hs-minutes-2026-06.pdf');

  -- ── public site content (Executive Board, stewards, meetings, updates) ──
  INSERT INTO public.site_officers (tenant_id, role_title, display_name, descriptor, email, sort_order) VALUES
   (t,'President','Adaeze Obi','Public Works','president@local79.demo',1),
   (t,'Vice-President','Marcus Delgado','Parks & Recreation','vp@local79.demo',2),
   (t,'Secretary-Treasurer','Sarah Whitecloud','Clerical & Administrative','treasurer@local79.demo',3),
   (t,'Recording Secretary','Priya Nair','Library','recsec@local79.demo',4),
   (t,'Trustee','Tomasz Kowalski','Transit','trustee@local79.demo',5),
   (t,'Chief Steward','Adaeze Obi','All units','chief.steward@local79.demo',6);

  INSERT INTO public.site_stewards (tenant_id, shift, area, steward_name, contact_method, sort_order) VALUES
   (t,'Days','Public Works / Water','Liam Fournier','steward.pw@local79.demo',1),
   (t,'Days','Parks & Recreation','Marcus Delgado','steward.parks@local79.demo',2),
   (t,'Days','Library / Clerical','Priya Nair','pnair@example.com',3),
   (t,'Rotating','Community & Social Services','Fatima Rahman','frahman@example.com',4);

  INSERT INTO public.site_meetings (tenant_id, meeting_type, title, starts_at, location, notes, schedule_note, sort_order) VALUES
   (t,'membership','General Membership Meeting','2026-07-21 19:00-04','Riverbend Community Hall','Bargaining update and Q2 financials.','Third Tuesday, monthly',1),
   (t,'executive','Executive Board Meeting','2026-08-03 18:00-04','Union Office','Board business (members welcome to observe).','First Monday, monthly',2),
   (t,'committee','Health & Safety Committee','2026-07-28 17:30-04','City Hall, Room 2B','Joint committee — review of recent incident reports.','Monthly',3);

  INSERT INTO public.site_posts (tenant_id, title, body, pinned, published_at) VALUES
   (t,'Renewal bargaining dates set','The bargaining committee has set dates with the City of Riverbend for the 2024–2027 renewal. Updates to follow at the General Membership Meeting.', true, '2026-07-02 09:00-04'),
   (t,'New Health & Safety representatives posted','Updated Joint Health & Safety Committee representatives are now listed for each unit.', false, '2026-06-05 09:00-04'),
   (t,'Roadmap: online ratification voting','Secure online ratification and officer-election voting is a planned future feature of The Union Hub. It is NOT yet available — ratification votes are currently conducted in person. (Shown here to illustrate the roadmap.)', false, '2026-06-20 09:00-04');

  INSERT INTO public.site_alerts (tenant_id, message, link_url, link_label, active, expires_at) VALUES
   (t,'Bargaining update meeting — Tuesday, July 21, 2026, 7:00 PM, Riverbend Community Hall.', NULL, NULL, true, '2026-07-22 00:00-04');

  RAISE NOTICE '[demo-seed] "Demo – Local 79" seeded (tenant %): 10 members, 5 stewards, 6 CBA articles, 6 grievances (1 arbitration, 1 closed), 4 documents, full public-site content. Voting = roadmap (post). Employers = text only.', t;
END $$;
