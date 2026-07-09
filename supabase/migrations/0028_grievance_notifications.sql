-- =============================================================================
-- 0028_grievance_notifications.sql
-- Deadline notification OUTBOX + tenant-scoped sweep.
--
-- Ports grievance-system's 0006_notifications.sql into the LIVE app, reconciled
-- onto the header-based tenancy + database-authorization model:
--   · tenant comes from the x-tenant-id header (get_request_tenant_id, 0002);
--   · authorization comes from the database (is_request_tenant_member /
--     is_request_tenant_admin, 0008/0022), NOT from the discarded
--     steward_profiles / steward_role / current_tenant_id model.
--
-- This table is a service-role OUTBOX: rows are written only by the scheduled
-- deadline sweep (check_deadlines_and_notify / run_deadline_notifications),
-- which run SECURITY DEFINER with EXECUTE granted to service_role ONLY. There
-- is deliberately NO authenticated INSERT policy — interactive users can read
-- their tenant's notifications, never enqueue them.
--
-- Depends on: 0001 (tenants), 0002 (get_request_tenant_id), 0008
--             (is_request_tenant_admin), 0022 (is_request_tenant_member),
--             0024 (grievance_cases, grievance_status),
--             0026 (grievance_deadlines), 0027 (view_grievance_pipeline: the
--             due_date/status_alert source the sweep reads).
--
-- Reconciled from source (0006_notifications.sql):
--   · current_tenant_id()  → get_request_tenant_id() (header resolver)
--   · RLS policy `for all` using current_tenant_id()
--        → tenant-scoped SELECT: tenant_id = get_request_tenant_id()
--          AND is_request_tenant_member()  (source did not scope to user_id,
--          so no per-user clause is added here)
--   · No reference to steward_profiles / steward_role / current_tenant_id.
--   · Preserves the outbox shape, dedup/undelivered indexes, the tenant-scoped
--     check_deadlines_and_notify(p_tenant_id) sweep, the cross-tenant
--     run_deadline_notifications() orchestrator, and the service-role-only
--     grant posture from the source.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Outbox (delivered_at distinguishes queued vs sent)
-- -----------------------------------------------------------------------------
create table public.grievance_notifications (
  id           uuid primary key default gen_random_uuid(),
  grievance_id uuid not null references public.grievance_cases(id) on delete cascade,
  tenant_id    uuid not null references public.tenants(id)         on delete cascade,
  user_id      uuid not null references auth.users(id)             on delete cascade,
  status_stage public.grievance_status not null,
  alert_type   text not null,
  message      text not null,
  sent_at      timestamptz not null default now(),  -- queued-at
  delivered_at timestamptz                           -- NULL = pending delivery
);

create index idx_notifications_dedup
  on public.grievance_notifications (grievance_id, status_stage, sent_at desc);
create index idx_notifications_tenant
  on public.grievance_notifications (tenant_id);
create index idx_notifications_undelivered
  on public.grievance_notifications (sent_at) where delivered_at is null;

-- -----------------------------------------------------------------------------
-- 2. check_deadlines_and_notify(p_tenant_id) — HARDENED, TENANT-SCOPED.
-- Every invocation is bound to exactly ONE tenant via the required p_tenant_id
-- argument, and EVERY query inside filters on it explicitly. There is no path
-- by which a single call touches another tenant's rows. Returns rows enqueued.
-- Reads deadline signals (status_alert / due_date) from view_grievance_pipeline
-- (0026); joins live grievance_cases (0024) for the assigned user.
-- -----------------------------------------------------------------------------
create or replace function public.check_deadlines_and_notify(p_tenant_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_inserted integer;
begin
  if p_tenant_id is null then
    raise exception 'check_deadlines_and_notify requires an explicit tenant id';
  end if;

  with candidates as (
    select
      p.grievance_id, p.tenant_id, p.case_number, p.due_date,
      p.current_status as status_stage, p.status_alert as alert_type,
      gc.assigned_to   as user_id
    from public.view_grievance_pipeline p
    join public.grievance_cases gc on gc.id = p.grievance_id
    where p.tenant_id = p_tenant_id            -- explicit tenant filter (pipeline)
      and gc.tenant_id = p_tenant_id           -- explicit tenant filter (case)
      and p.status_alert in ('OVERDUE', 'DUE_SOON')
      and gc.assigned_to is not null
  ),
  inserted as (
    insert into public.grievance_notifications
      (grievance_id, tenant_id, user_id, status_stage, alert_type, message)
    select
      c.grievance_id, c.tenant_id, c.user_id, c.status_stage, c.alert_type,
      case c.alert_type
        when 'OVERDUE' then 'Case ' || c.case_number || ' is OVERDUE at stage '
             || c.status_stage || ' (was due ' || to_char(c.due_date, 'YYYY-MM-DD') || ').'
        else 'Case ' || c.case_number || ' is DUE SOON at stage '
             || c.status_stage || ' (due ' || to_char(c.due_date, 'YYYY-MM-DD') || ').'
      end
    from candidates c
    where not exists (
      select 1 from public.grievance_notifications n
      where n.grievance_id = c.grievance_id
        and n.status_stage = c.status_stage
        and n.tenant_id    = p_tenant_id       -- explicit tenant filter (dedup)
        and n.sent_at > now() - interval '24 hours'
    )
    returning 1
  )
  select count(*) into v_inserted from inserted;

  return v_inserted;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. run_deadline_notifications() — orchestrator for the scheduled job.
-- Iterates tenants and calls the tenant-scoped function once per tenant. This
-- is the ONLY cross-tenant surface, it is service-role/cron only, and it does
-- no row work itself — each tenant's rows are processed in isolation.
-- -----------------------------------------------------------------------------
create or replace function public.run_deadline_notifications()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_total integer := 0;
  t       record;
begin
  for t in select id from public.tenants loop
    v_total := v_total + public.check_deadlines_and_notify(t.id);
  end loop;
  return v_total;
end;
$$;

-- Both functions are backend-only. Revoke from every interactive role; the
-- scheduled job runs as service_role / postgres.
revoke all on function public.check_deadlines_and_notify(uuid) from public, anon, authenticated;
revoke all on function public.run_deadline_notifications()    from public, anon, authenticated;
grant execute on function public.check_deadlines_and_notify(uuid) to service_role;
grant execute on function public.run_deadline_notifications()    to service_role;

-- =============================================================================
-- 4. Row-Level Security
-- Outbox: authenticated users may only READ their own tenant's notifications
-- (header tenant match + real DB membership of that tenant). Writes come solely
-- from the service-role sweep above, so there is NO authenticated INSERT/UPDATE/
-- DELETE policy and no such grants.
-- =============================================================================
alter table public.grievance_notifications enable row level security;
alter table public.grievance_notifications force  row level security;

create policy notifications_select on public.grievance_notifications
  for select to authenticated
  using (
    tenant_id = public.get_request_tenant_id()
    and public.is_request_tenant_member()
  );

grant select on public.grievance_notifications to authenticated;

-- After applying: NOTIFY pgrst, 'reload schema';
