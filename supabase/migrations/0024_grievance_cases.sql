-- =============================================================================
-- 0024_grievance_cases.sql
-- Grievance cases + immutable status history. Implements SOFT DELETE.
--
-- Ports grievance-system's 0003_grievances.sql into the LIVE app, reconciled
-- onto the header-based tenancy + database-authorization model:
--   · tenant comes from the x-tenant-id header (get_request_tenant_id, 0002);
--   · authorization comes from the database (is_request_tenant_member /
--     is_request_tenant_admin), NOT from the discarded steward_profiles model.
--
-- Depends on: 0001 (tenants, set_updated_at), 0002 (members,
--             get_request_tenant_id), 0008 (is_request_tenant_admin),
--             0022 (is_request_tenant_member).
--
-- Reconciled from source (0003_grievances.sql):
--   · current_tenant_id()              → get_request_tenant_id() (header resolver)
--   · current_user_is_admin/privileged → is_request_tenant_admin() (not used in
--                                          this file — writes are member-gated)
--   · RLS predicate                    → tenant_id = get_request_tenant_id()
--                                          AND is_request_tenant_member()
--   · tenant_id columns get the server-stamped default get_request_tenant_id().
--   · No reference to steward_profiles / steward_role / current_tenant_id.
--   · Preserves the grievance_status enum, unique(tenant_id, case_number),
--     soft-delete, indexes, immutable-history triggers, and the status-change
--     logging trigger from the source.
--   · Does NOT touch the dormant live public.grievances stub (0017).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Lifecycle status enum
-- -----------------------------------------------------------------------------
create type public.grievance_status as enum (
  'INTAKE', 'STEP_1', 'STEP_2', 'STEP_3', 'ARBITRATION', 'CLOSED'
);

-- -----------------------------------------------------------------------------
-- 2. grievance_cases
-- SOFT DELETE: rows are never hard-deleted by the app (no DELETE policy below).
-- "Deleting" a case = setting deleted_at, which preserves grievance_history.
-- -----------------------------------------------------------------------------
create table public.grievance_cases (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null default public.get_request_tenant_id()
                     references public.tenants(id) on delete cascade,
  member_id        uuid not null references public.members(id) on delete restrict,
  case_number      text not null,
  current_status   public.grievance_status not null default 'INTAKE',
  date_incident    date,
  date_filed       date not null default current_date,
  contract_article text,
  description      text,
  assigned_to      uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  deleted_at       timestamptz,                      -- soft-delete marker
  unique (tenant_id, case_number)
);

create index idx_grievance_cases_tenant on public.grievance_cases (tenant_id);
create index idx_grievance_cases_member on public.grievance_cases (member_id);
-- Most queries want only live cases; index the common predicate.
create index idx_grievance_cases_active
  on public.grievance_cases (tenant_id) where deleted_at is null;

-- -----------------------------------------------------------------------------
-- 3. grievance_history (immutable audit of status transitions)
-- -----------------------------------------------------------------------------
create table public.grievance_history (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null default public.get_request_tenant_id()
                 references public.tenants(id) on delete cascade,
  grievance_id uuid not null references public.grievance_cases(id) on delete cascade,
  changed_by   uuid references auth.users(id) on delete set null,
  from_status  text,
  to_status    text not null,
  notes        text,
  changed_at   timestamptz not null default now()
);

create index idx_grievance_history_case   on public.grievance_history (grievance_id);
create index idx_grievance_history_tenant on public.grievance_history (tenant_id);

-- Immutability: append-only. Block UPDATE/DELETE even for elevated roles.
create or replace function public.prevent_history_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'grievance_history is append-only; % is not permitted', tg_op;
end;
$$;

create trigger trg_grievance_history_no_mutation
  before update or delete on public.grievance_history
  for each row execute function public.prevent_history_mutation();

-- -----------------------------------------------------------------------------
-- 4. Status-change logger — HARDENED with explicit tenant guard.
-- -----------------------------------------------------------------------------
create or replace function public.log_grievance_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_tenant uuid := public.get_request_tenant_id();
begin
  if v_caller_tenant is not null and new.tenant_id is distinct from v_caller_tenant then
    raise exception 'tenant mismatch in grievance audit (row % vs caller %)',
      new.tenant_id, v_caller_tenant using errcode = 'check_violation';
  end if;

  if tg_op = 'INSERT' then
    insert into public.grievance_history
      (tenant_id, grievance_id, changed_by, from_status, to_status, notes)
    values
      (new.tenant_id, new.id, auth.uid(), null, new.current_status::text, 'Case intake');

  elsif tg_op = 'UPDATE' and new.current_status is distinct from old.current_status then
    insert into public.grievance_history
      (tenant_id, grievance_id, changed_by, from_status, to_status, notes)
    values
      (new.tenant_id, new.id, auth.uid(),
       old.current_status::text, new.current_status::text, null);
  end if;

  return new;
end;
$$;

create trigger trg_grievance_log_insert
  after insert on public.grievance_cases
  for each row execute function public.log_grievance_change();

create trigger trg_grievance_log_status_change
  after update on public.grievance_cases
  for each row
  when (old.current_status is distinct from new.current_status)
  execute function public.log_grievance_change();

-- =============================================================================
-- 5. Row-Level Security  (SOFT DELETE enforced here)
-- =============================================================================
alter table public.grievance_cases   enable row level security;
alter table public.grievance_cases   force  row level security;
alter table public.grievance_history enable row level security;
alter table public.grievance_history force  row level security;

-- NOTE: there is deliberately NO DELETE policy on grievance_cases. Authenticated
-- users cannot hard-delete a case (which would cascade and destroy history);
-- they soft-delete by UPDATE deleted_at = now(). Live rows only on SELECT.
--
-- Authorization: header tenant match + real DB membership of that tenant
-- (is_request_tenant_member() — admin OR steward). A signed-in user forging
-- another tenant's x-tenant-id has no membership row there → RLS denies.
create policy grievance_select on public.grievance_cases
  for select to authenticated
  using (
    tenant_id = public.get_request_tenant_id()
    and public.is_request_tenant_member()
    and deleted_at is null
  );

create policy grievance_insert on public.grievance_cases
  for insert to authenticated
  with check (
    tenant_id = public.get_request_tenant_id()
    and public.is_request_tenant_member()
  );

create policy grievance_update on public.grievance_cases
  for update to authenticated
  using (
    tenant_id = public.get_request_tenant_id()
    and public.is_request_tenant_member()
  )
  with check (
    tenant_id = public.get_request_tenant_id()
    and public.is_request_tenant_member()
  );

-- grievance_history: readable within tenant by members; INSERTs happen only via
-- the SECURITY DEFINER logging trigger; UPDATE/DELETE blocked by trigger above.
create policy grievance_history_select on public.grievance_history
  for select to authenticated
  using (
    tenant_id = public.get_request_tenant_id()
    and public.is_request_tenant_member()
  );

create policy grievance_history_insert on public.grievance_history
  for insert to authenticated
  with check (
    tenant_id = public.get_request_tenant_id()
    and public.is_request_tenant_member()
  );

-- -----------------------------------------------------------------------------
-- 6. Grants
-- -----------------------------------------------------------------------------
grant select, insert, update on public.grievance_cases   to authenticated;
grant select, insert         on public.grievance_history to authenticated;

-- After applying: NOTIFY pgrst, 'reload schema';
