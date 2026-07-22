-- ════════════════════════════════════════════════════════════════════════
-- demo_seed.sql — "Demo – CUPE Local 79" demonstration tenant  (EXPANDED)
-- ════════════════════════════════════════════════════════════════════════
-- A FIRST-CLASS TENANT, not a special mode. Uses ONLY the existing production
-- schema — no new tables, no demo flags, no bypasses, no demo-only logic.
-- Everything here is reachable through the same RLS / auth / workflows a real
-- customer uses. Only the DATA is different.
--
-- PURPOSE: make the demo feel like a Local that has operated for many years, so
-- that searching returns real institutional memory. Grievances connect to
-- Collective-Agreement articles, prior settlements, arbitration outcomes,
-- precedents (grievance_precedents) and steward knowledge (knowledge_entries).
-- Search "Attendance", "Accommodation", "Vacation", "Discipline", "Overtime",
-- "Seniority" and each returns multiple historical, interconnected records.
--
-- ⚠ NAMING DEVIATION (recorded, informed): the display name uses "CUPE", a REAL
--   federation acronym, and "Local 79" resembles a real Toronto local. This
--   VIOLATES UX design/MOCKUP-RULES.md ("no real federation acronyms"), which is
--   marked non-negotiable in CLAUDE.md. It is set here only on the explicit,
--   informed instruction of the project owner (who chose it over the compliant
--   "Demo – Local 79" after the conflict + trademark/impersonation risk were
--   flagged). /brandcheck WILL flag this line — that is expected and correct.
--   To revert to compliant, change the single display_name value below.
--   Everything else — every member, steward, grievance, document, note — is
--   ENTIRELY FICTIONAL. No real people, employers, cases, or confidential data.
--
-- IDEMPOTENT + TENANT-SCOPED: resolves the demo tenant by slug and deletes /
-- reloads ONLY rows WHERE tenant_id = <demo id>. Never reads or writes another
-- tenant's rows. Does NOT touch migration 0041, the isolation suite, the
-- validation gate, or any customer data. Run as a role that bypasses RLS
-- (postgres / service_role), like any seed:
--   npx --no-install supabase db query --db-url "<url>" -f supabase/demo/demo_seed.sql
--
-- ⚠ NOT EXECUTED HERE: this file was authored and SYNTAX-REVIEWED against the
--   schema (migrations 0001–0041); it has NOT been run against a database in
--   this environment (no DB available). Treat a clean apply as unverified until
--   observed on the demo/staging tenant.
-- ════════════════════════════════════════════════════════════════════════

INSERT INTO public.tenants (slug, display_name, local_number, union_type, accent_hex, contact_email, status)
VALUES ('demo', 'Demo – CUPE Local 79', '79', 'Municipal / Public Sector', '#2F5D7C', 'demo@theunionhub.ca', 'active')
ON CONFLICT (slug) DO UPDATE
  SET display_name = EXCLUDED.display_name, local_number = EXCLUDED.local_number,
      union_type = EXCLUDED.union_type, accent_hex = EXCLUDED.accent_hex, status = EXCLUDED.status;

DO $$
DECLARE
  t   uuid;
  -- steward login accounts (auth.users). The demo admin signs in via the tenant
  -- contact_email bootstrap, NOT these. These exist so stewards can be assigned
  -- to grievances (grievance_cases.assigned_to → auth.users) and author
  -- knowledge_entries (user_id → auth.users).
  su1 uuid := 'd0de0001-0000-4000-8000-000000000001'; -- Chief Steward
  su2 uuid := 'd0de0001-0000-4000-8000-000000000002'; -- Public Works / Water
  su3 uuid := 'd0de0001-0000-4000-8000-000000000003'; -- Parks & Recreation
  su4 uuid := 'd0de0001-0000-4000-8000-000000000004'; -- Library / Clerical
  su5 uuid := 'd0de0001-0000-4000-8000-000000000005'; -- Community & Social Services
  su6 uuid := 'd0de0001-0000-4000-8000-000000000006'; -- Transit
  -- deterministic fictional-data pools for the generated members
  fn      text[]  := ARRAY['Adaeze','Liam','Priya','Marcus','Sarah','Tomasz','Fatima','Grace','Daniel','Chloe','Noah','Ava','Wei','Aisha','Diego','Hana','Omar','Leah','Kwame','Sofia','Ivan','Mei','Jamal','Elena','Raj','Nadia','Cole','Yuki','Hassan','Bianca','Sean','Amara','Luca','Zoe','Andre','Nour','Felix','Ingrid','Tariq','Rosa','Ben','Salma','Victor','Keiko','Dylan','Farah','Owen','Petra','Kofi','Maya'];
  ln      text[]  := ARRAY['Obi','Fournier','Nair','Delgado','Whitecloud','Kowalski','Rahman','Okonkwo','Petrov','Tremblay','Singh','Nguyen','Adeyemi','Costa','Larsson','Haddad','Romano','Chen','Ferreira','Kaur','Boateng','Novak','Reyes','Ivanova','Mensah','Dubois','OBrien','Yamamoto','Ali','Santos','Walsh','Diallo','Bianchi','Popov','Murphy','Khan','Schmidt','Andersson','Aziz','Marchetti','Cohen','Osei','Vargas','Tanaka','Byrne','Saleh','Doyle','Novakova','Owusu','Prasad'];
  depts   text[]  := ARRAY['Public Works','Water & Wastewater','Parks & Recreation','Library','Clerical & Administrative','Transit','Community & Social Services','By-law Enforcement'];
  classes text[]  := ARRAY['Labourer','Heavy Equipment Operator','Water Treatment Operator','Parks Maintenance','Library Technician','Administrative Clerk II','Transit Operator','Social Services Worker','By-law Enforcement Officer','Recreation Programmer','Mechanic','Custodian'];
  sites   text[]  := ARRAY['Riverbend Yards','Riverbend WTP','Central Branch','Lakeshore Park','City Hall','Riverbend Transit','Community Centre','Aquatic Centre','North Depot','Fleet Garage'];
  i       int;
BEGIN
  SELECT id INTO t FROM public.tenants WHERE slug = 'demo';
  IF t IS NULL THEN RAISE EXCEPTION '[demo-seed] demo tenant missing'; END IF;

  -- ── clean (scoped to the demo tenant only; child → parent order) ─────────
  DELETE FROM public.grievance_precedents WHERE tenant_id = t;
  DELETE FROM public.grievance_history     WHERE tenant_id = t;
  DELETE FROM public.grievance_cases       WHERE tenant_id = t;   -- also cascades history
  DELETE FROM public.knowledge_entries     WHERE tenant_id = t;
  DELETE FROM public.documents             WHERE tenant_id = t;
  DELETE FROM public.cba_articles          WHERE tenant_id = t;
  DELETE FROM public.stewards              WHERE tenant_id = t;
  DELETE FROM public.members               WHERE tenant_id = t;
  DELETE FROM public.site_alerts           WHERE tenant_id = t;
  DELETE FROM public.site_posts            WHERE tenant_id = t;
  DELETE FROM public.site_officers         WHERE tenant_id = t;
  DELETE FROM public.site_stewards         WHERE tenant_id = t;
  DELETE FROM public.site_meetings         WHERE tenant_id = t;

  -- ── steward login accounts (fictional; never receive mail) ───────────────
  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at) VALUES
    (su1,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','chief.steward@local79.demo', now(), now()),
    (su2,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','steward.pw@local79.demo',    now(), now()),
    (su3,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','steward.parks@local79.demo', now(), now()),
    (su4,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','steward.library@local79.demo', now(), now()),
    (su5,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','steward.css@local79.demo',   now(), now()),
    (su6,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','steward.transit@local79.demo', now(), now())
  ON CONFLICT (id) DO NOTHING;

  -- ── core cast members (named; referenced by grievances / officers) ───────
  -- UUIDs d0de0000-…-0000000000NN  (1–10)
  INSERT INTO public.members (id, tenant_id, full_name, first_name, last_name, status, membership_status,
                              email, job_classification, department, location, seniority_date) VALUES
   ('d0de0000-0000-4000-8000-000000000001', t,'Adaeze Obi','Adaeze','Obi','active','ACTIVE','aobi@example.com','Heavy Equipment Operator','Public Works','Riverbend Yards','2004-05-11'),
   ('d0de0000-0000-4000-8000-000000000002', t,'Liam Fournier','Liam','Fournier','active','ACTIVE','lfournier@example.com','Water Treatment Operator','Water & Wastewater','Riverbend WTP','2008-09-02'),
   ('d0de0000-0000-4000-8000-000000000003', t,'Priya Nair','Priya','Nair','active','ACTIVE','pnair@example.com','Library Technician','Library','Central Branch','2011-01-18'),
   ('d0de0000-0000-4000-8000-000000000004', t,'Marcus Delgado','Marcus','Delgado','active','ACTIVE','mdelgado@example.com','Parks Maintenance','Parks & Recreation','Lakeshore Park','2006-06-25'),
   ('d0de0000-0000-4000-8000-000000000005', t,'Sarah Whitecloud','Sarah','Whitecloud','active','ACTIVE','swhitecloud@example.com','Administrative Clerk II','Clerical & Administrative','City Hall','2015-03-04'),
   ('d0de0000-0000-4000-8000-000000000006', t,'Tomasz Kowalski','Tomasz','Kowalski','active','ACTIVE','tkowalski@example.com','Transit Operator','Transit','Riverbend Transit','2010-11-14'),
   ('d0de0000-0000-4000-8000-000000000007', t,'Fatima Rahman','Fatima','Rahman','active','ACTIVE','frahman@example.com','Social Services Worker','Community & Social Services','Community Centre','2013-08-19'),
   ('d0de0000-0000-4000-8000-000000000008', t,'Grace Okonkwo','Grace','Okonkwo','active','ACTIVE','gokonkwo@example.com','By-law Enforcement Officer','By-law Enforcement','City Hall','2016-02-27'),
   ('d0de0000-0000-4000-8000-000000000009', t,'Daniel Petrov','Daniel','Petrov','inactive','INACTIVE','dpetrov@example.com','Labourer','Public Works','Riverbend Yards','2019-07-06'),
   ('d0de0000-0000-4000-8000-000000000010', t,'Chloe Tremblay','Chloe','Tremblay','active','ACTIVE','ctremblay@example.com','Recreation Programmer','Parks & Recreation','Aquatic Centre','2018-10-12');

  -- ── generated members (≈340) — deterministic UUIDs d0de0100-…-0000000000NN ─
  -- Procedural, tenant-scoped, fictional. member_number is left to the
  -- auto-assign trigger (0035); we never set it here.
  FOR i IN 1..340 LOOP
    INSERT INTO public.members (id, tenant_id, full_name, first_name, last_name, status, membership_status,
                                email, job_classification, department, location, seniority_date)
    VALUES (
      ('d0de0100-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, t,
      fn[1 + (i * 7)  % array_length(fn,1)]      || ' ' || ln[1 + (i * 13) % array_length(ln,1)],
      fn[1 + (i * 7)  % array_length(fn,1)],
      ln[1 + (i * 13) % array_length(ln,1)],
      CASE WHEN i % 23 = 0 THEN 'inactive' ELSE 'active' END,
      CASE WHEN i % 23 = 0 THEN 'INACTIVE' ELSE 'ACTIVE' END,
      'member' || i || '@example.com',
      classes[1 + (i * 5)  % array_length(classes,1)],
      depts[1 + (i * 3)     % array_length(depts,1)],
      sites[1 + (i * 11)    % array_length(sites,1)],
      (date '2003-01-01' + ((i * 37) % 8000))
    );
  END LOOP;

  -- ── stewards (Chief + unit stewards) ─────────────────────────────────────
  INSERT INTO public.stewards (id, tenant_id, user_id, full_name, title, email, worksite, status, appointed_at) VALUES
   ('d0de0002-0000-4000-8000-000000000001', t, su1,  'Adaeze Obi','Chief Steward','chief.steward@local79.demo','All units','active','2016-01-01'),
   ('d0de0002-0000-4000-8000-000000000002', t, su2,  'Liam Fournier','Unit Steward','steward.pw@local79.demo','Public Works / Water','active','2017-03-01'),
   ('d0de0002-0000-4000-8000-000000000003', t, su3,  'Marcus Delgado','Unit Steward','steward.parks@local79.demo','Parks & Recreation','active','2015-06-01'),
   ('d0de0002-0000-4000-8000-000000000004', t, su4,  'Priya Nair','Unit Steward','steward.library@local79.demo','Library / Clerical','active','2018-09-01'),
   ('d0de0002-0000-4000-8000-000000000005', t, su5,  'Fatima Rahman','Unit Steward','steward.css@local79.demo','Community & Social Services','active','2019-02-01'),
   ('d0de0002-0000-4000-8000-000000000006', t, su6,  'Tomasz Kowalski','Unit Steward','steward.transit@local79.demo','Transit','active','2018-05-01'),
   ('d0de0002-0000-4000-8000-000000000007', t, NULL, 'Grace Okonkwo','Alternate Steward','gokonkwo@example.com','By-law Enforcement','active','2020-04-01'),
   ('d0de0002-0000-4000-8000-000000000008', t, NULL, 'Chloe Tremblay','Alternate Steward','ctremblay@example.com','Parks & Recreation','active','2021-01-01');

  -- ── Collective Agreement articles (Riverbend Municipal CA 2024–2027) ─────
  -- Fuller CA so theme searches hit an article + the grievances/precedents on it.
  INSERT INTO public.cba_articles (tenant_id, article_number, title, body) VALUES
   (t,'Article 6','Hours of Work','Standard work week, shift scheduling, and notice of schedule change for full- and part-time employees of the City of Riverbend.'),
   (t,'Article 7','Overtime','Overtime rates, and the requirement that overtime be offered on an equalized basis by seniority within classification and department.'),
   (t,'Article 8','Scheduling & Shift Changes','Posting of schedules, minimum notice for shift changes, and premiums for short-notice changes.'),
   (t,'Article 9','Seniority','Definition, accrual, and application of seniority in layoffs, recalls, job postings, and vacation selection.'),
   (t,'Article 10','Job Postings & Promotions','Vacancies posted seven (7) calendar days; awarded on qualifications and seniority; trial period provisions.'),
   (t,'Article 11','Layoff & Recall','Order of layoff by seniority, bumping rights, and recall order and notice.'),
   (t,'Article 12','Vacation','Vacation entitlement by years of service, vacation scheduling by seniority, and carryover limits.'),
   (t,'Article 13','Leaves of Absence','Bereavement, jury duty, union, parental, and unpaid personal leaves.'),
   (t,'Article 14','Sick Leave & Attendance','Sick-leave accrual, medical documentation, and the Attendance Management Program and its limits.'),
   (t,'Article 15','Health & Safety','Joint Health & Safety Committee, right to refuse unsafe work, and provision of protective equipment.'),
   (t,'Article 16','Discipline & Discharge','Progressive discipline, just cause, right to representation, and removal of discipline from file after a set period.'),
   (t,'Article 17','Grievance & Arbitration Procedure','Steps, time limits, and referral to arbitration; policy and group grievances.'),
   (t,'Article 18','Duty to Accommodate & Human Rights','No discrimination; duty to accommodate disability, family status, and creed to the point of undue hardship.'),
   (t,'Article 19','Meal & Rest Periods','Paid and unpaid break entitlements and scheduling.'),
   (t,'Article 20','Contracting Out','Restrictions on contracting out bargaining-unit work and notice to the Union.'),
   (t,'Article 21','Wages & Classification','Wage grids, classification, reclassification, and acting-pay provisions.');

  RAISE NOTICE '[demo-seed] base loaded (tenant %): 350 members, 8 stewards, 16 CBA articles.', t;
END $$;


-- ════════════════════════════════════════════════════════════════════════
-- INSTITUTIONAL KNOWLEDGE — grievances, history, precedent, steward notes.
-- Deliberately spans 2015–2026 with many CLOSED cases so a search for a theme
-- ("Attendance", "Accommodation", "Vacation", "Discipline", "Overtime",
-- "Seniority") returns a cluster: the article, the past grievances, how they
-- resolved (grievance_precedents), and the stewards' own notes
-- (knowledge_entries). Employers appear as TEXT only. All fictional.
-- ════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  t   uuid;
  su1 uuid := 'd0de0001-0000-4000-8000-000000000001';
  su2 uuid := 'd0de0001-0000-4000-8000-000000000002';
  su3 uuid := 'd0de0001-0000-4000-8000-000000000003';
  su4 uuid := 'd0de0001-0000-4000-8000-000000000004';
  su5 uuid := 'd0de0001-0000-4000-8000-000000000005';
  su6 uuid := 'd0de0001-0000-4000-8000-000000000006';
BEGIN
  SELECT id INTO t FROM public.tenants WHERE slug = 'demo';

  -- ── grievances (deterministic UUIDs d0de0003-…-0000000000NN) ─────────────
  INSERT INTO public.grievance_cases (id, tenant_id, member_id, case_number, current_status, date_incident, date_filed, contract_article, description, assigned_to) VALUES
   -- ATTENDANCE (Article 14)
   ('d0de0003-0000-4000-8000-000000000001',t,'d0de0000-0000-4000-8000-000000000006','GRV-2016-0044','CLOSED','2016-02-08','2016-02-15','Article 14','Attendance Management Program: Transit Operator placed on Step 3 attendance counselling for absences that were disability-related. Union argued the program cannot count protected absences. Resolved — record corrected, protected days removed.',su6),
   ('d0de0003-0000-4000-8000-000000000002',t,'d0de0100-0000-4000-8000-000000000021','GRV-2018-0067','CLOSED','2018-09-03','2018-09-10','Article 14','Attendance: employee disciplined under the Attendance Management Program without the required review meeting. Settled — discipline reduced to a non-disciplinary letter, meeting rights affirmed.',su1),
   ('d0de0003-0000-4000-8000-000000000003',t,'d0de0100-0000-4000-8000-000000000112','GRV-2021-0033','CLOSED','2021-04-19','2021-04-27','Article 14','Attendance Management: culminating termination for innocent absenteeism. Referred to arbitration; arbitrator reinstated with conditions — City did not establish undue hardship. Key attendance precedent.',su1),
   ('d0de0003-0000-4000-8000-000000000004',t,'d0de0100-0000-4000-8000-000000000205','GRV-2024-0058','STEP_2','2024-06-11','2024-06-18','Article 14','Attendance: written warning issued for absences the grievor says are protected medical leave. Union requesting removal.',su5),
   -- ACCOMMODATION (Article 18)
   ('d0de0003-0000-4000-8000-000000000005',t,'d0de0100-0000-4000-8000-000000000048','GRV-2017-0091','CLOSED','2017-05-22','2017-05-30','Article 18','Duty to accommodate: employer refused a modified-duties return-to-work for a Parks worker with a lifting restriction. Settled — graduated return-to-work plan implemented; accommodation precedent established.',su3),
   ('d0de0003-0000-4000-8000-000000000006',t,'d0de0100-0000-4000-8000-000000000077','GRV-2019-0102','CLOSED','2019-11-04','2019-11-12','Article 18','Accommodation of family status: shift schedule conflicted with childcare; employer denied adjustment. Resolved — schedule accommodation granted after Union cited family-status obligations.',su4),
   ('d0de0003-0000-4000-8000-000000000007',t,'d0de0100-0000-4000-8000-000000000160','GRV-2022-0076','ARBITRATION','2022-08-15','2022-08-23','Article 18','Accommodation (creed): denial of a prayer-break arrangement. Referred to arbitration on the extent of the duty to accommodate short of undue hardship.',su1),
   ('d0de0003-0000-4000-8000-000000000008',t,'d0de0000-0000-4000-8000-000000000007','GRV-2025-0011','STEP_3','2025-02-10','2025-02-18','Article 18','Accommodation: Social Services Worker with a documented disability seeking ergonomic equipment and modified caseload; employer delay. Union alleges failure to accommodate.',su5),
   -- VACATION (Article 12)
   ('d0de0003-0000-4000-8000-000000000009',t,'d0de0100-0000-4000-8000-000000000019','GRV-2015-0022','CLOSED','2015-06-01','2015-06-09','Article 12','Vacation: senior employee denied first choice of summer vacation, which was granted to a junior worker. Resolved — vacation reselected by seniority; scheduling practice corrected.',su2),
   ('d0de0003-0000-4000-8000-000000000010',t,'d0de0100-0000-4000-8000-000000000133','GRV-2020-0049','CLOSED','2020-03-14','2020-03-20','Article 12','Vacation carryover: earned vacation cancelled and not carried over during a staffing shortage. Settled — days restored and paid out per the carryover provision.',su1),
   ('d0de0003-0000-4000-8000-000000000011',t,'d0de0100-0000-4000-8000-000000000241','GRV-2023-0088','CLOSED','2023-05-27','2023-06-02','Article 12','Vacation: employer refused a vacation request citing operational needs without offering alternatives. Resolved at Step 2 — request granted; guidance issued on vacation scheduling by seniority.',su3),
   ('d0de0003-0000-4000-8000-000000000012',t,'d0de0100-0000-4000-8000-000000000260','GRV-2026-0041','INTAKE','2026-06-30','2026-07-06','Article 12','Vacation: short-notice denial of an approved vacation day. Intake — gathering the approval history.',su4),
   -- DISCIPLINE (Article 16)
   ('d0de0003-0000-4000-8000-000000000013',t,'d0de0000-0000-4000-8000-000000000004','GRV-2016-0071','CLOSED','2016-10-12','2016-10-19','Article 16','Discipline: three-day suspension for an alleged safety infraction; Union argued no just cause and improper investigation. Settled — suspension reduced to a verbal warning, removed after 12 months.',su3),
   ('d0de0003-0000-4000-8000-000000000014',t,'d0de0100-0000-4000-8000-000000000090','GRV-2018-0130','CLOSED','2018-12-01','2018-12-07','Article 16','Discipline: written warning issued without a representation offer at the investigatory meeting. Resolved — warning rescinded; Weingarten-style representation rights reaffirmed.',su1),
   ('d0de0003-0000-4000-8000-000000000015',t,'d0de0000-0000-4000-8000-000000000004','GRV-2026-0019','ARBITRATION','2025-11-10','2025-11-17','Article 16','Discharge of a Parks & Recreation employee; Union asserts absence of just cause and disproportionate penalty. Referred to arbitration after Step 3 denial. Discipline lifecycle showpiece.',su3),
   ('d0de0003-0000-4000-8000-000000000016',t,'d0de0100-0000-4000-8000-000000000188','GRV-2022-0114','CLOSED','2022-07-08','2022-07-15','Article 16','Discipline: culminating suspension relying on prior discipline that should have been removed from file under the sunset clause. Settled — penalty vacated; file cleared.',su2),
   ('d0de0003-0000-4000-8000-000000000017',t,'d0de0000-0000-4000-8000-000000000008','GRV-2026-0028','STEP_1','2026-06-02','2026-06-05','Article 16','Discipline: by-law officer given a written reprimand over a complaint; Union questions the investigation and just cause.',su1),
   -- OVERTIME (Article 7)
   ('d0de0003-0000-4000-8000-000000000018',t,'d0de0000-0000-4000-8000-000000000002','GRV-2026-0031','STEP_2','2026-05-20','2026-05-26','Article 7','Overtime at the Riverbend Water Treatment Plant assigned out of seniority order; grievor skipped for a weekend call-in. Denied at Step 1.',su2),
   ('d0de0003-0000-4000-8000-000000000019',t,'d0de0100-0000-4000-8000-000000000054','GRV-2017-0059','CLOSED','2017-03-09','2017-03-16','Article 7','Overtime equalization: overtime not distributed on an equalized basis over the quarter. Settled — equalization owed hours paid; tracking sheet implemented.',su2),
   ('d0de0003-0000-4000-8000-000000000020',t,'d0de0100-0000-4000-8000-000000000144','GRV-2020-0081','CLOSED','2020-09-21','2020-09-28','Article 7','Overtime: mandatory overtime assigned without offering by seniority. Resolved — practice corrected; missed-opportunity pay to affected senior employees.',su6),
   -- SENIORITY / POSTINGS (Article 9 / 10)
   ('d0de0003-0000-4000-8000-000000000021',t,'d0de0000-0000-4000-8000-000000000003','GRV-2026-0022','STEP_3','2026-04-08','2026-04-14','Article 10','Library Technician posting awarded to a junior applicant; grievor has greater seniority and equal qualifications (Riverbend Public Library Board).',su4),
   ('d0de0003-0000-4000-8000-000000000022',t,'d0de0100-0000-4000-8000-000000000066','GRV-2015-0088','CLOSED','2015-09-30','2015-10-07','Article 10','Job posting: qualifications assessed inconsistently between applicants. Settled — posting re-run with a standardized scoring matrix.',su1),
   ('d0de0003-0000-4000-8000-000000000023',t,'d0de0100-0000-4000-8000-000000000201','GRV-2019-0044','CLOSED','2019-04-02','2019-04-09','Article 9','Seniority: seniority list miscalculated for a part-time to full-time conversion, affecting shift selection. Resolved — list corrected; seniority date restored.',su6),
   ('d0de0003-0000-4000-8000-000000000024',t,'d0de0100-0000-4000-8000-000000000029','GRV-2023-0102','CLOSED','2023-10-18','2023-10-24','Article 10','Promotion: trial period failed without a fair opportunity or training. Settled — returned to former position without loss of seniority; training plan for future trials.',su3),
   -- HEALTH & SAFETY (Article 15)
   ('d0de0003-0000-4000-8000-000000000025',t,'d0de0000-0000-4000-8000-000000000001','GRV-2026-0029','STEP_1','2026-06-02','2026-06-05','Article 15','Public Works crew directed to operate equipment without required guarding; health & safety concern and work refusal raised with the City of Riverbend.',su2),
   ('d0de0003-0000-4000-8000-000000000026',t,'d0de0100-0000-4000-8000-000000000097','GRV-2017-0120','CLOSED','2017-11-15','2017-11-22','Article 15','Health & safety: protective equipment not provided for a winter road crew. Resolved — equipment issued; JHSC review scheduled.',su2),
   ('d0de0003-0000-4000-8000-000000000027',t,'d0de0100-0000-4000-8000-000000000175','GRV-2021-0095','CLOSED','2021-08-30','2021-09-07','Article 15','Health & safety: reprisal alleged after a work refusal. Settled — no reprisal language reaffirmed; supervisor training ordered.',su1),
   -- SCHEDULING (Article 8 / 6)
   ('d0de0003-0000-4000-8000-000000000028',t,'d0de0000-0000-4000-8000-000000000008','GRV-2026-0035','INTAKE','2026-07-09','2026-07-14','Article 6','Repeated short-notice schedule changes for By-law Enforcement contrary to the hours-of-work provisions.',su1),
   ('d0de0003-0000-4000-8000-000000000029',t,'d0de0100-0000-4000-8000-000000000123','GRV-2018-0038','CLOSED','2018-04-11','2018-04-18','Article 8','Scheduling: shift changed with less than the required notice and no premium paid. Settled — short-notice premium paid; notice practice corrected.',su6),
   ('d0de0003-0000-4000-8000-000000000030',t,'d0de0100-0000-4000-8000-000000000232','GRV-2022-0050','CLOSED','2022-05-05','2022-05-12','Article 8','Scheduling: schedule posted late repeatedly at the Aquatic Centre. Resolved — posting deadline enforced; make-whole for a wrongly scheduled day.',su3),
   -- OTHER THEMES
   ('d0de0003-0000-4000-8000-000000000031',t,'d0de0100-0000-4000-8000-000000000140','GRV-2019-0150','CLOSED','2019-12-09','2019-12-16','Article 20','Contracting out: bargaining-unit landscaping work contracted out without notice to the Union. Settled — work returned in-house; notice protocol agreed.',su3),
   ('d0de0003-0000-4000-8000-000000000032',t,'d0de0100-0000-4000-8000-000000000058','GRV-2020-0120','CLOSED','2020-11-02','2020-11-09','Article 11','Layoff & recall: recall order not followed by seniority after a seasonal layoff. Resolved — recall re-ordered; lost wages paid.',su2),
   ('d0de0003-0000-4000-8000-000000000033',t,'d0de0100-0000-4000-8000-000000000084','GRV-2023-0033','CLOSED','2023-03-01','2023-03-08','Article 16','Discipline: attendance-related suspension overlapping a protected leave. Settled — suspension removed; interplay of attendance and leave clarified.',su5),
   ('d0de0003-0000-4000-8000-000000000034',t,'d0de0100-0000-4000-8000-000000000151','GRV-2024-0102','STEP_2','2024-09-14','2024-09-20','Article 13','Leaves: bereavement leave denied for a step-relative not listed in the article; Union argues functional-family interpretation.',su1),
   ('d0de0003-0000-4000-8000-000000000035',t,'d0de0000-0000-4000-8000-000000000006','GRV-2025-0104','CLOSED','2025-08-01','2025-08-06','Article 9','Transit Operator recall order; resolved in the Union''s favour at Step 2 — grievor reinstated to the schedule by seniority.',su6),
   ('d0de0003-0000-4000-8000-000000000036',t,'d0de0100-0000-4000-8000-000000000112','GRV-2024-0140','CLOSED','2024-11-19','2024-11-26','Article 14','Attendance: second Attendance Management review citing the 2021 case; Union relied on the prior arbitration award to halt escalation. Resolved — escalation withdrawn.',su1);

  -- ── grievance history (status trail on a few multi-step / arbitration cases) ─
  INSERT INTO public.grievance_history (tenant_id, grievance_id, changed_by, from_status, to_status, notes, changed_at) VALUES
   (t,'d0de0003-0000-4000-8000-000000000015',su3,'INTAKE','STEP_1','Filed with the department; representation meeting held.','2025-11-17 10:00-05'),
   (t,'d0de0003-0000-4000-8000-000000000015',su3,'STEP_1','STEP_2','Denied at Step 1; escalated with member statement.','2025-11-28 10:00-05'),
   (t,'d0de0003-0000-4000-8000-000000000015',su1,'STEP_2','STEP_3','Denied at Step 2; Chief Steward added prior-discipline analysis.','2025-12-15 10:00-05'),
   (t,'d0de0003-0000-4000-8000-000000000015',su1,'STEP_3','ARBITRATION','Step 3 denied; referred to arbitration — just cause and penalty in issue.','2026-01-20 10:00-05'),
   (t,'d0de0003-0000-4000-8000-000000000003',su1,'STEP_3','ARBITRATION','Referred to arbitration on innocent absenteeism.','2021-06-10 10:00-04'),
   (t,'d0de0003-0000-4000-8000-000000000003',su1,'ARBITRATION','CLOSED','Award: reinstated with conditions; protected absences not counted.','2021-11-30 10:00-05'),
   (t,'d0de0003-0000-4000-8000-000000000035',su6,'STEP_1','STEP_2','Recall order challenged; seniority list attached.','2025-08-12 10:00-04'),
   (t,'d0de0003-0000-4000-8000-000000000035',su6,'STEP_2','CLOSED','Resolved in the Union''s favour; reinstated by seniority.','2025-08-25 10:00-04');

  -- ── precedents (grievance × article → how it resolved + lessons) ─────────
  -- The searchable "how did we win this last time" layer. article_id via lookup.
  INSERT INTO public.grievance_precedents (tenant_id, grievance_id, article_id, resolution_summary, lessons_learned, created_by)
  SELECT t, g.gid, a.id, g.summary, g.lesson, g.author
  FROM (VALUES
   ('d0de0003-0000-4000-8000-000000000001'::uuid,'Article 14','Protected (disability-related) absences removed from the Attendance Management count; record corrected.','Protected absences cannot be counted toward attendance thresholds — always audit the absence record for medical/leave days first.',su6),
   ('d0de0003-0000-4000-8000-000000000003'::uuid,'Article 14','Arbitrator reinstated with conditions; City failed to prove undue hardship for innocent absenteeism.','For innocent absenteeism the employer must show excessive absence AND no reasonable likelihood of improvement AND undue hardship. Get the medical prognosis early.',su1),
   ('d0de0003-0000-4000-8000-000000000036'::uuid,'Article 14','Escalation withdrawn after the Union cited the 2021 arbitration award (GRV-2021-0033).','Prior awards bind future attendance escalations — keep the award on file and cite it at the first review.',su1),
   ('d0de0003-0000-4000-8000-000000000005'::uuid,'Article 18','Graduated return-to-work plan implemented for a lifting restriction.','Modified duties must be actively canvassed; a blanket "no light duty" is not accommodation to undue hardship.',su3),
   ('d0de0003-0000-4000-8000-000000000006'::uuid,'Article 18','Schedule adjusted to accommodate family-status childcare obligations.','Family status accommodation applies to bona fide childcare conflicts — document the conflict and alternatives tried.',su4),
   ('d0de0003-0000-4000-8000-000000000009'::uuid,'Article 12','Vacation reselected by seniority; junior award reversed.','Seniority governs vacation choice — challenge junior awards within the time limit and attach the seniority list.',su2),
   ('d0de0003-0000-4000-8000-000000000010'::uuid,'Article 12','Cancelled vacation restored and paid out under the carryover provision.','Earned vacation cannot simply be erased for staffing — carryover/payout is owed.',su1),
   ('d0de0003-0000-4000-8000-000000000013'::uuid,'Article 16','Suspension reduced to a verbal warning; removed after 12 months.','A flawed investigation undercuts just cause — attack the process, then the penalty; invoke the sunset clause.',su3),
   ('d0de0003-0000-4000-8000-000000000014'::uuid,'Article 16','Warning rescinded for denial of representation at an investigatory meeting.','Representation must be offered at any meeting that may lead to discipline — no rep, no discipline.',su1),
   ('d0de0003-0000-4000-8000-000000000016'::uuid,'Article 16','Culminating penalty vacated because prior discipline should have been sunset off the file.','Always check whether relied-on prior discipline is still live under the removal clause.',su2),
   ('d0de0003-0000-4000-8000-000000000019'::uuid,'Article 7','Equalization hours paid; a tracking sheet was implemented.','Overtime must equalize over the defined period — keep an independent OT tally.',su2),
   ('d0de0003-0000-4000-8000-000000000020'::uuid,'Article 7','Missed-opportunity pay to senior employees for overtime not offered by seniority.','Even "mandatory" OT must first be offered by seniority.',su6),
   ('d0de0003-0000-4000-8000-000000000022'::uuid,'Article 10','Posting re-run with a standardized scoring matrix.','Inconsistent qualification scoring is grievable — demand the scoring criteria.',su1),
   ('d0de0003-0000-4000-8000-000000000023'::uuid,'Article 9','Seniority list corrected after a PT→FT conversion error.','Audit seniority dates on every status conversion.',su6),
   ('d0de0003-0000-4000-8000-000000000029'::uuid,'Article 8','Short-notice premium paid; notice practice corrected.','Schedule changes below the notice threshold trigger a premium — track the posting time.',su6),
   ('d0de0003-0000-4000-8000-000000000031'::uuid,'Article 20','Contracted-out landscaping work returned in-house; notice protocol agreed.','Contracting out of unit work requires notice — grieve promptly to preserve the remedy.',su3),
   ('d0de0003-0000-4000-8000-000000000032'::uuid,'Article 11','Recall re-ordered by seniority; lost wages paid.','Recall follows seniority — compare the recall list to the seniority list immediately.',su2),
   ('d0de0003-0000-4000-8000-000000000035'::uuid,'Article 9','Reinstated to the schedule by seniority at Step 2.','A clean seniority argument can resolve early — lead with the list.',su6)
  ) AS g(gid, art, summary, lesson, author)
  JOIN public.cba_articles a ON a.tenant_id = t AND a.article_number = g.art;

  -- ── knowledge_entries (steward notes / arbitration & settlement memory) ──
  INSERT INTO public.knowledge_entries (tenant_id, user_id, title, issue_type, current_state, timeline, handoff_notes) VALUES
   (t,su1,'Attendance Management — playbook','Attendance','The City escalates innocent absenteeism through the Attendance Management Program. Protected medical/leave absences must not be counted.','Audit the absence record; separate protected days; request the medical prognosis; cite GRV-2021-0033 award at the first review.','If I''m unavailable: the 2021 arbitration award is the anchor precedent — it halted the 2024 escalation too (GRV-2024-0140).'),
   (t,su1,'Innocent absenteeism arbitration (GRV-2021-0033)','Attendance','Arbitrator reinstated with conditions; City could not prove undue hardship.','Filed 2021-04; arbitration 2021-06; award 2021-11.','Award PDF is in Documents (arbitration). Use the three-part test: excessive absence + no prognosis of improvement + undue hardship.'),
   (t,su3,'Duty to accommodate — return to work','Accommodation','Modified/graduated return-to-work must be actively canvassed; blanket refusals fail.','Get the functional abilities form; propose specific modified duties; document each option tried.','See GRV-2017-0091 settlement for the graduated RTW template.'),
   (t,su4,'Family-status accommodation','Accommodation','Bona fide childcare conflicts trigger the duty to accommodate scheduling.','Document the conflict, the alternatives the member tried, and the employer''s response.','GRV-2019-0102 got the schedule adjusted — same argument.'),
   (t,su1,'Creed accommodation (at arbitration)','Accommodation','Prayer-break arrangement denied; referred to arbitration on undue hardship.','Ongoing — GRV-2022-0076.','Employer argues operational coverage; our position is short paid/unpaid breaks are not undue hardship.'),
   (t,su2,'Vacation by seniority','Vacation','Senior members choose first; junior awards over a senior member are grievable within the time limit.','Attach the seniority list; file before the window closes.','GRV-2015-0022 reversed a junior award; GRV-2023-0088 got a denial overturned at Step 2.'),
   (t,su1,'Vacation carryover / cancellation','Vacation','Earned vacation cannot be erased for staffing — carryover or payout is owed.','Confirm the accrual; cite the carryover clause.','GRV-2020-0049 restored cancelled days.'),
   (t,su3,'Discipline — attack the process first','Discipline','Flawed investigations undercut just cause. Check representation rights and the discipline-removal (sunset) clause.','Get the investigation notes; confirm a rep was offered; check whether relied-on prior discipline is still live.','GRV-2016-0071, GRV-2018-0130, and GRV-2022-0114 all turned on process. The discharge GRV-2026-0019 is at arbitration.'),
   (t,su1,'Representation rights at meetings','Discipline','No representation offer at a meeting that may lead to discipline = discipline rescinded.','If management calls a meeting, ask if it could lead to discipline; if yes, a steward attends.','GRV-2018-0130 is the clean example.'),
   (t,su2,'Overtime equalization','Overtime','OT must be offered by seniority and equalized over the period — even mandatory OT.','Keep an independent OT tally per member; compare quarterly.','GRV-2017-0059 (equalization pay) and GRV-2020-0081 (missed-opportunity pay) are the precedents.'),
   (t,su6,'Overtime out of seniority (active)','Overtime','WTP call-in skipped a senior operator; at Step 2.','GRV-2026-0031 — need the call-in log and the OT tally.','Employer''s Step 1 answer claims urgency; our tally shows equalization was owed anyway.'),
   (t,su1,'Job postings & qualifications','Seniority','Where qualifications are relatively equal, seniority governs. Demand the scoring criteria.','Get the posting, the applications, and the scoring matrix.','GRV-2015-0088 forced a re-run with a standardized matrix; GRV-2026-0022 is live at Step 3.'),
   (t,su6,'Seniority list audits','Seniority','Errors appear on PT→FT conversions and layoffs/recalls.','Audit the seniority date on every status change.','GRV-2019-0044 corrected a conversion error; GRV-2025-0104 resolved a recall by seniority.'),
   (t,su2,'Health & safety — refusals & reprisal','Health & Safety','Right to refuse unsafe work; no reprisal for exercising it.','Document the hazard, the refusal, and the JHSC involvement.','GRV-2017-0120 (PPE) and GRV-2021-0095 (reprisal) — reprisal language reaffirmed.'),
   (t,su6,'Scheduling & short-notice premium','Health & Safety','Schedule changes below the notice threshold trigger a premium.','Screenshot the posting time; note the change time.','GRV-2018-0038 and GRV-2022-0050 — premium paid and posting deadline enforced.'),
   (t,su3,'Contracting out of unit work','Discipline','Contracting out bargaining-unit work requires notice; grieve promptly to keep the remedy.','Identify the work, the contractor, and whether notice was given.','GRV-2019-0150 returned landscaping work in-house.'),
   (t,su5,'Attendance vs. protected leave overlap','Attendance','Discipline that overlaps a protected leave is vulnerable.','Line up the discipline dates against approved leave dates.','GRV-2023-0033 removed a suspension that overlapped a leave.'),
   (t,su1,'Employer''s usual arguments (settlement notes)','Discipline','Common City positions: "operational needs", "progressive discipline", "urgency". Each has a counter.','Keep this note current after each settlement.','Operational needs ≠ automatic denial; progressive discipline needs a live record; urgency still requires offering OT by seniority.');

  RAISE NOTICE '[demo-seed] knowledge loaded (tenant %): 36 grievances, 8 history rows, 18 precedents, 18 knowledge entries.', t;
END $$;


-- ════════════════════════════════════════════════════════════════════════
-- LEGAL DOCUMENT CORPUS + PUBLIC SITE
-- documents.category is NOT NULL (enum AGREEMENT | LOU | ARBITRATION) — the
-- earlier seed omitted it and would fail on the 0040+ schema; fixed here. The
-- corpus is the CA, Letters of Understanding, and arbitration awards (the
-- searchable legal record). Bylaws / forms / minutes / newsletters live in the
-- public-site tables (site_posts / site_meetings), not documents.
-- ════════════════════════════════════════════════════════════════════════
DO $$
DECLARE t uuid;
BEGIN
  SELECT id INTO t FROM public.tenants WHERE slug = 'demo';

  INSERT INTO public.documents (tenant_id, filename, file_type, storage_path, category) VALUES
   (t,'Riverbend-Municipal-Collective-Agreement-2024-2027.pdf','application/pdf','demo/ca-2024-2027.pdf','AGREEMENT'),
   (t,'Riverbend-Municipal-Collective-Agreement-2021-2024.pdf','application/pdf','demo/ca-2021-2024.pdf','AGREEMENT'),
   (t,'LOU-01-Return-to-Work-and-Accommodation.pdf','application/pdf','demo/lou-01-rtw-accommodation.pdf','LOU'),
   (t,'LOU-02-Overtime-Equalization-Tracking.pdf','application/pdf','demo/lou-02-overtime-equalization.pdf','LOU'),
   (t,'LOU-03-Attendance-Management-Review-Process.pdf','application/pdf','demo/lou-03-attendance-review.pdf','LOU'),
   (t,'Arbitration-Award-2021-Innocent-Absenteeism-GRV-2021-0033.pdf','application/pdf','demo/arb-2021-attendance.pdf','ARBITRATION'),
   (t,'Arbitration-Award-2019-Overtime-Equalization.pdf','application/pdf','demo/arb-2019-overtime.pdf','ARBITRATION'),
   (t,'Arbitration-Award-2018-Just-Cause-Discipline.pdf','application/pdf','demo/arb-2018-discipline.pdf','ARBITRATION'),
   (t,'Arbitration-Award-2017-Duty-to-Accommodate.pdf','application/pdf','demo/arb-2017-accommodation.pdf','ARBITRATION'),
   (t,'Arbitration-Brief-2026-Discharge-GRV-2026-0019.pdf','application/pdf','demo/arb-2026-discharge-brief.pdf','ARBITRATION');

  -- ── public site: Executive Board ────────────────────────────────────────
  INSERT INTO public.site_officers (tenant_id, role_title, display_name, descriptor, email, sort_order) VALUES
   (t,'President','Adaeze Obi','Public Works','president@local79.demo',1),
   (t,'Vice-President','Marcus Delgado','Parks & Recreation','vp@local79.demo',2),
   (t,'Secretary-Treasurer','Sarah Whitecloud','Clerical & Administrative','treasurer@local79.demo',3),
   (t,'Recording Secretary','Priya Nair','Library','recsec@local79.demo',4),
   (t,'Chief Steward','Adaeze Obi','All units','chief.steward@local79.demo',5),
   (t,'Trustee','Tomasz Kowalski','Transit','trustee1@local79.demo',6),
   (t,'Trustee','Fatima Rahman','Community & Social Services','trustee2@local79.demo',7),
   (t,'Trustee','Grace Okonkwo','By-law Enforcement','trustee3@local79.demo',8);

  INSERT INTO public.site_stewards (tenant_id, shift, area, steward_name, contact_method, sort_order) VALUES
   (t,'Days','Public Works / Water','Liam Fournier','steward.pw@local79.demo',1),
   (t,'Days','Parks & Recreation','Marcus Delgado','steward.parks@local79.demo',2),
   (t,'Days','Library / Clerical','Priya Nair','steward.library@local79.demo',3),
   (t,'Rotating','Community & Social Services','Fatima Rahman','steward.css@local79.demo',4),
   (t,'Rotating','Transit','Tomasz Kowalski','steward.transit@local79.demo',5);

  INSERT INTO public.site_meetings (tenant_id, meeting_type, title, starts_at, location, notes, schedule_note, sort_order) VALUES
   (t,'membership','General Membership Meeting','2026-07-21 19:00-04','Riverbend Community Hall','Bargaining update and Q2 financials.','Third Tuesday, monthly',1),
   (t,'executive','Executive Board Meeting','2026-08-03 18:00-04','Union Office','Board business (members welcome to observe).','First Monday, monthly',2),
   (t,'committee','Health & Safety Committee','2026-07-28 17:30-04','City Hall, Room 2B','Joint committee — review of recent incident reports.','Monthly',3),
   (t,'committee','Bargaining Committee','2026-07-30 17:00-04','Union Office','Renewal proposals: attendance language, accommodation, overtime equalization.','As scheduled',4);

  INSERT INTO public.site_posts (tenant_id, title, body, pinned, published_at) VALUES
   (t,'Renewal bargaining dates set','The bargaining committee has set dates with the City of Riverbend for the 2024–2027 renewal. Priorities from the membership survey: attendance-management language, accommodation, and overtime equalization. Updates at the General Membership Meeting.', true, '2026-07-02 09:00-04'),
   (t,'Steward newsletter — Summer 2026','Case round-up for stewards: recent wins on vacation-by-seniority and short-notice scheduling premiums; reminder to file within time limits; the Attendance playbook is updated in the knowledge base.', false, '2026-06-25 09:00-04'),
   (t,'New Health & Safety representatives posted','Updated Joint Health & Safety Committee representatives are now listed for each unit.', false, '2026-06-05 09:00-04'),
   (t,'Know your rights: representation at meetings','If management calls a meeting that could lead to discipline, you have the right to a steward. Ask first, then call your steward.', false, '2026-05-12 09:00-04'),
   (t,'Roadmap: online ratification voting','Secure online ratification and officer-election voting is a planned future feature of The Union Hub. It is NOT yet available — ratification votes are currently conducted in person. (Shown here to illustrate the roadmap.)', false, '2026-04-20 09:00-04');

  INSERT INTO public.site_alerts (tenant_id, message, link_url, link_label, active, expires_at) VALUES
   (t,'Bargaining update meeting — Tuesday, July 21, 2026, 7:00 PM, Riverbend Community Hall.', NULL, NULL, true, '2026-07-22 00:00-04');

  RAISE NOTICE '[demo-seed] "Demo – CUPE Local 79" complete (tenant %): legal corpus (10 docs: CA/LOU/arbitration), full Executive Board, stewards, meetings, newsletters. Employers = text only. Voting = roadmap (post).', t;
END $$;
