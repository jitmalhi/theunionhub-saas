-- =============================================================================
-- 0027_grievance_pipeline.sql
-- view_grievance_pipeline: case + current-stage deadline, with alert flags.
--
-- Ports grievance-system's 0005_pipeline_view.sql into the LIVE app, reconciled
-- onto the header-based tenancy + database-authorization model. The view carries
-- NO tenant predicate of its own: it is declared WITH (security_invoker = true),
-- so it runs as the CALLER and the underlying tables' RLS supplies both tenant
-- isolation and membership scoping (get_request_tenant_id + is_request_tenant_member,
-- see 0024). Do not re-implement that scoping here.
--
-- Depends on: 0024 (grievance_cases, grievance_status, soft-delete),
--             0026 (grievance_deadlines).
--
-- Reconciled from source (0005_pipeline_view.sql):
--   · No current_tenant_id() reference existed in the source view body; tenancy
--     was (and remains) enforced by the base tables' RLS via security_invoker.
--   · No reference to steward_profiles / steward_role / current_tenant_id.
--   · Preserves the selected columns, the status_alert
--     (OVERDUE / DUE_SOON / HEALTHY) and days_until_due logic, the join on
--     status_stage = current_status, and the deleted_at is null filter.
-- =============================================================================
-- security_invoker = true: the view runs as the CALLER, so the base tables'
-- tenant-isolation + membership RLS applies. Without it the view would run as
-- owner and leak across tenants. Soft-deleted cases are excluded (deleted_at
-- is null).
-- =============================================================================
create or replace view public.view_grievance_pipeline
with (security_invoker = true) as
select
  gc.id             as grievance_id,
  gc.tenant_id,
  gc.case_number,
  gc.current_status,
  gd.due_date,
  date_part('day', gd.due_date - current_timestamp)::int as days_until_due,
  case
    when gd.due_date is null
      then 'HEALTHY'
    when gd.due_date < current_timestamp and gc.current_status <> 'CLOSED'
      then 'OVERDUE'
    when gd.due_date <= current_timestamp + interval '3 days'
      then 'DUE_SOON'
    else 'HEALTHY'
  end as status_alert,
  gc.assigned_to,
  gc.date_filed
from public.grievance_cases gc
left join public.grievance_deadlines gd
  on  gd.grievance_id = gc.id
  and gd.status_stage = gc.current_status
where gc.deleted_at is null;

grant select on public.view_grievance_pipeline to authenticated;

-- After applying: NOTIFY pgrst, 'reload schema';
