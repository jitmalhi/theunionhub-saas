-- =============================================================================
-- 0026_grievance_deadlines.sql
-- Contractual deadline tracker: per-tenant configurable rules + auto-computed
-- per-stage deadlines.
--
-- Ports grievance-system's 0004_deadlines.sql into the LIVE app, reconciled
-- onto the header-based tenancy + database-authorization model:
--   · tenant comes from the x-tenant-id header (get_request_tenant_id, 0002);
--   · authorization comes from the database (is_request_tenant_member /
--     is_request_tenant_admin), NOT from the discarded steward_profiles model.
--
-- Depends on: 0001 (tenants), 0002 (get_request_tenant_id),
--             0008 (is_request_tenant_admin), 0022 (is_request_tenant_member),
--             0024 (grievance_cases, grievance_status, current_status).
--
-- Reconciled from source (0004_deadlines.sql):
--   · current_tenant_id()            → get_request_tenant_id() (header resolver)
--   · grievance role fns / privileged writes → is_request_tenant_admin()
--   · member-readable RLS            → tenant_id = get_request_tenant_id()
--                                        AND is_request_tenant_member()
--   · rules writes are privileged    → is_request_tenant_admin()
--   · rules SELECT preserves global-default visibility (tenant_id IS NULL rows
--     readable to everyone in a tenant), exactly as the source.
--   · No reference to steward_profiles / steward_role / current_tenant_id.
--   · Preserves the get_deadline_days / calculate_next_deadline helpers, the
--     set_grievance_deadline trigger (attached to grievance_cases from 0024),
--     and the seeded default deadline rules.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Configurable rules (tenant override; tenant_id NULL = global default)
-- -----------------------------------------------------------------------------
create table public.grievance_deadline_rules (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid references public.tenants(id) on delete cascade,  -- NULL = default
  status_stage public.grievance_status not null,
  days_allowed integer,                                               -- NULL = no deadline
  created_at   timestamptz not null default now(),
  unique (tenant_id, status_stage)
);

-- Enforce one global-default row per stage (table UNIQUE ignores NULL tenant).
create unique index uq_deadline_rules_global
  on public.grievance_deadline_rules (status_stage) where tenant_id is null;

insert into public.grievance_deadline_rules (tenant_id, status_stage, days_allowed) values
  (null, 'INTAKE', 10),
  (null, 'STEP_1', 10),
  (null, 'STEP_2', 15),
  (null, 'STEP_3', 20),
  (null, 'ARBITRATION', 30),
  (null, 'CLOSED', null);

-- -----------------------------------------------------------------------------
-- 2. Deadlines table (one row per grievance/stage)
-- tenant_id gets the server-stamped default get_request_tenant_id(); rows are
-- upserted by the SECURITY DEFINER trigger below.
-- -----------------------------------------------------------------------------
create table public.grievance_deadlines (
  id           uuid primary key default gen_random_uuid(),
  grievance_id uuid not null references public.grievance_cases(id) on delete cascade,
  tenant_id    uuid not null default public.get_request_tenant_id()
                 references public.tenants(id) on delete cascade,
  status_stage public.grievance_status not null,
  days_allowed integer,
  due_date     timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (grievance_id, status_stage)
);

create index idx_grievance_deadlines_tenant on public.grievance_deadlines (tenant_id);
create index idx_grievance_deadlines_due    on public.grievance_deadlines (due_date);

-- -----------------------------------------------------------------------------
-- 3. Lookup + calculation helpers (SECURITY DEFINER to read global defaults)
-- -----------------------------------------------------------------------------
create or replace function public.get_deadline_days(
  p_tenant_id uuid, p_status_stage public.grievance_status
) returns integer
language sql stable security definer set search_path = public, pg_temp
as $$
  select days_allowed
  from public.grievance_deadline_rules
  where status_stage = p_status_stage
    and (tenant_id = p_tenant_id or tenant_id is null)
  order by tenant_id nulls last
  limit 1;
$$;

create or replace function public.calculate_next_deadline(
  p_status_stage public.grievance_status, p_tenant_id uuid
) returns timestamptz
language sql stable security definer set search_path = public, pg_temp
as $$
  select case when d is null then null
              else current_timestamp + make_interval(days => d) end
  from (select public.get_deadline_days(p_tenant_id, p_status_stage) as d) t;
$$;

-- -----------------------------------------------------------------------------
-- 4. Trigger: upsert the deadline for the case's current stage.
-- Attaches to public.grievance_cases (created in 0024). SECURITY DEFINER so the
-- upsert into grievance_deadlines bypasses RLS on the audit path.
-- -----------------------------------------------------------------------------
create or replace function public.set_grievance_deadline()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_days integer;
  v_due  timestamptz;
begin
  v_days := public.get_deadline_days(new.tenant_id, new.current_status);
  v_due  := public.calculate_next_deadline(new.current_status, new.tenant_id);

  insert into public.grievance_deadlines
    (grievance_id, tenant_id, status_stage, days_allowed, due_date)
  values
    (new.id, new.tenant_id, new.current_status, v_days, v_due)
  on conflict (grievance_id, status_stage) do update set
    days_allowed = excluded.days_allowed,
    due_date     = excluded.due_date,
    updated_at   = now();

  return new;
end;
$$;

create trigger trg_grievance_deadline_insert
  after insert on public.grievance_cases
  for each row execute function public.set_grievance_deadline();

create trigger trg_grievance_deadline_update
  after update on public.grievance_cases
  for each row
  when (old.current_status is distinct from new.current_status)
  execute function public.set_grievance_deadline();

-- =============================================================================
-- 5. Row-Level Security
-- =============================================================================
alter table public.grievance_deadline_rules enable row level security;
alter table public.grievance_deadline_rules force  row level security;
alter table public.grievance_deadlines      enable row level security;
alter table public.grievance_deadlines      force  row level security;

-- Deadlines: readable/writable within the header tenant by real DB members
-- (is_request_tenant_member() — admin OR steward). A signed-in user forging
-- another tenant's x-tenant-id has no membership row there → RLS denies.
create policy grievance_deadlines_select on public.grievance_deadlines
  for select to authenticated
  using (
    tenant_id = public.get_request_tenant_id()
    and public.is_request_tenant_member()
  );

create policy grievance_deadlines_write on public.grievance_deadlines
  for all to authenticated
  using (
    tenant_id = public.get_request_tenant_id()
    and public.is_request_tenant_member()
  )
  with check (
    tenant_id = public.get_request_tenant_id()
    and public.is_request_tenant_member()
  );

-- Rules: read own tenant + global defaults (tenant_id IS NULL); write only own
-- tenant's rules, and only by verified admins of the header tenant.
create policy grievance_deadline_rules_read on public.grievance_deadline_rules
  for select to authenticated
  using (
    tenant_id = public.get_request_tenant_id()
    or tenant_id is null
  );

create policy grievance_deadline_rules_write on public.grievance_deadline_rules
  for all to authenticated
  using (
    tenant_id = public.get_request_tenant_id()
    and public.is_request_tenant_admin()
  )
  with check (
    tenant_id = public.get_request_tenant_id()
    and public.is_request_tenant_admin()
  );

-- -----------------------------------------------------------------------------
-- 6. Grants
-- -----------------------------------------------------------------------------
grant select, insert, update, delete on public.grievance_deadline_rules to authenticated;
grant select, insert, update, delete on public.grievance_deadlines      to authenticated;

-- After applying: NOTIFY pgrst, 'reload schema';
