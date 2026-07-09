-- =============================================================================
-- 0030_ai_generations.sql
-- AI service layer — usage & cost ledger (per-local AI spend audit).
-- Append-only audit of every model call: who, when, case, model, token usage,
-- and estimated cost, tenant-scoped so AI spend is trackable PER LOCAL.
--
-- Ports grievance-system's 0010_ai_generations.sql into the LIVE app,
-- reconciled onto the header-based tenancy + database-authorization model:
--   · tenant comes from the x-tenant-id header (get_request_tenant_id, 0002);
--   · authorization comes from the database (is_request_tenant_admin, 0008),
--     NOT from the discarded steward_profiles / steward_role model.
--
-- Depends on: 0001 (tenants), 0008 (is_request_tenant_admin),
--             0024 (grievance_cases).
--
-- Reconciled from source (0010_ai_generations.sql):
--   · current_tenant_id()                       → get_request_tenant_id()
--   · current_user_is_privileged/is_admin()     → is_request_tenant_admin()
--   · grievance_id FK  → public.grievance_cases(id) (0024), not the dormant
--                        public.grievances stub (0017).
--   · No reference to steward_profiles / steward_role / current_tenant_id.
--   · Everything else about the table is IDENTICAL to the source: the
--     append-only usage+cost ledger columns, the UPDATE/DELETE-blocking
--     triggers, and the security_invoker ai_cost_by_month reporting view.
--
-- Writes come ONLY from the ai-service Edge Function using the service role,
-- which stamps tenant_id/created_by from the verified JWT identity. There is no
-- INSERT path for authenticated users — the client cannot forge a usage row.
-- =============================================================================

create type public.ai_generation_status as enum ('ok', 'refusal', 'error');

create table public.ai_generations (
  id                          uuid primary key default gen_random_uuid(),
  tenant_id                   uuid not null
                                references public.tenants(id) on delete cascade,
  created_by                  uuid references auth.users(id) on delete set null,
  feature                     text not null,          -- 'draft_grievance' | 'quality_review' | ...
  grievance_id                uuid references public.grievance_cases(id) on delete set null,

  provider                    text not null,          -- 'anthropic'
  model                       text not null,          -- 'claude-opus-4-8'

  -- token usage (mirrors the Anthropic usage object)
  input_tokens                integer not null default 0,
  output_tokens               integer not null default 0,
  cache_creation_input_tokens integer not null default 0,
  cache_read_input_tokens     integer not null default 0,

  -- cost: estimated at write time from token usage + a versioned price table
  estimated_cost_usd          numeric(12, 6) not null default 0,
  pricing_version             text not null default 'unknown',

  status                      public.ai_generation_status not null default 'ok',
  stop_reason                 text,
  error                       text,
  duration_ms                 integer,
  output_sha256               text,                   -- hash of the output, NOT the raw draft

  created_at                  timestamptz not null default now()
);

create index idx_ai_generations_tenant      on public.ai_generations (tenant_id);
create index idx_ai_generations_tenant_time on public.ai_generations (tenant_id, created_at);
create index idx_ai_generations_case        on public.ai_generations (grievance_id);

-- -----------------------------------------------------------------------------
-- Append-only: block UPDATE/DELETE for everyone, including elevated roles.
-- (Same posture as grievance_history — the cost/usage record cannot be rewritten.)
-- -----------------------------------------------------------------------------
create or replace function public.prevent_ai_generations_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'ai_generations is append-only (% blocked)', tg_op
    using errcode = 'restrict_violation';
end;
$$;

create trigger trg_ai_generations_no_update
  before update on public.ai_generations
  for each row execute function public.prevent_ai_generations_mutation();

create trigger trg_ai_generations_no_delete
  before delete on public.ai_generations
  for each row execute function public.prevent_ai_generations_mutation();

-- -----------------------------------------------------------------------------
-- RLS: tenant-scoped read. No INSERT/UPDATE/DELETE policy for authenticated —
-- writes are service-role only (Edge Function). A steward sees their own AI
-- calls; a tenant ADMIN sees the whole local's spend.
-- -----------------------------------------------------------------------------
alter table public.ai_generations enable row level security;
alter table public.ai_generations force row level security;

create policy ai_generations_select on public.ai_generations
  for select to authenticated
  using (
    tenant_id = public.get_request_tenant_id()
    and (
      created_by = auth.uid()
      or public.is_request_tenant_admin()
    )
  );

revoke insert, update, delete on public.ai_generations from authenticated;
grant  select on public.ai_generations to authenticated;

-- -----------------------------------------------------------------------------
-- Reporting: per-tenant monthly cost rollup. security_invoker => the caller's
-- RLS applies, so a local only ever sees its own spend.
-- -----------------------------------------------------------------------------
create or replace view public.ai_cost_by_month
  with (security_invoker = true) as
  select
    tenant_id,
    date_trunc('month', created_at)                as month,
    count(*)                                        as calls,
    sum(input_tokens)                               as input_tokens,
    sum(output_tokens)                              as output_tokens,
    sum(cache_read_input_tokens)                    as cache_read_tokens,
    round(sum(estimated_cost_usd), 4)              as cost_usd
  from public.ai_generations
  group by tenant_id, date_trunc('month', created_at);

grant select on public.ai_cost_by_month to authenticated;

-- After applying: NOTIFY pgrst, 'reload schema';
