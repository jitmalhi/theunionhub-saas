-- =============================================================================
-- 0025_cba_precedents.sql
-- Institutional memory: CBA articles + grievance precedents (the "knowledge"
-- layer — outcomes/lessons captured at debrief time, not just process state).
-- Ported from grievance-system 0009_grievance_precedents.sql, reconciled onto
-- the live app's header-tenant + database-authorization model.
--
-- Depends on: 0001 (tenants), 0002 (get_request_tenant_id),
--             0022 (is_request_tenant_member, get_user_role),
--             0024 (grievance_cases).
--
-- Reconciliation (grievance-system → live):
--   · current_tenant_id()                       → get_request_tenant_id()
--   · current_user_is_admin/_privileged()       → is_request_tenant_admin()
--   · steward_profiles / steward_role / current_tenant_id  → DISCARDED (unused).
--   · Isolation policies split into SELECT + write, each gated on the DATABASE
--     authorization decision is_request_tenant_member() (a steward or admin of
--     the header tenant), never the x-tenant-id header alone. A steward debriefs
--     their own tenant's cases, so writes are member-gated (not admin-only).
--   · FKs retargeted to live tables: grievance_id → public.grievance_cases(id)
--     (0024), article_id → public.cba_articles(id), created_by → auth.users(id).
--   · Server-stamped tenant_id/created_by defaults, the (grievance_id, article_id)
--     uniqueness, indexes, and the cross-entity integrity trigger are preserved;
--     the trigger now reads the live grievance_cases / cba_articles tables while
--     keeping its same-tenant invariant.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. cba_articles — the collective agreement, as queryable entities (per tenant)
-- tenant_id is stamped SERVER-SIDE from the request header; the client must not
-- supply it.
-- -----------------------------------------------------------------------------
create table if not exists public.cba_articles (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null default public.get_request_tenant_id()
                   references public.tenants(id) on delete cascade,
  article_number text not null,        -- e.g. '12.3'
  title          text not null,        -- e.g. 'Overtime Distribution'
  body           text,                 -- full clause text (optional)
  created_at     timestamptz not null default now(),
  unique (tenant_id, article_number)
);
create index if not exists idx_cba_articles_tenant on public.cba_articles (tenant_id);

-- -----------------------------------------------------------------------------
-- 2. grievance_precedents — the harvested knowledge of a resolved grievance.
-- tenant_id / created_by are stamped SERVER-SIDE (defaults below); the client
-- must not supply them. This is what makes the archive trustworthy.
-- -----------------------------------------------------------------------------
create table if not exists public.grievance_precedents (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null default public.get_request_tenant_id()
                       references public.tenants(id) on delete cascade,
  grievance_id       uuid not null references public.grievance_cases(id) on delete cascade,
  article_id         uuid not null references public.cba_articles(id) on delete restrict,
  resolution_summary text not null,
  lessons_learned    text,
  created_by         uuid default auth.uid() references auth.users(id) on delete set null,
  created_at         timestamptz not null default now(),
  -- one precedent per (grievance, article); a grievance citing several articles
  -- yields several precedent rows.
  unique (grievance_id, article_id)
);
create index if not exists idx_precedents_tenant  on public.grievance_precedents (tenant_id);
create index if not exists idx_precedents_article on public.grievance_precedents (article_id);
create index if not exists idx_precedents_case    on public.grievance_precedents (grievance_id);

-- -----------------------------------------------------------------------------
-- 3. Relationship integrity: a precedent's grievance AND article must both
-- belong to the same tenant as the precedent itself. SECURITY DEFINER so it can
-- read the referenced rows regardless of the caller's RLS, then enforce the
-- cross-entity tenant invariant the FKs alone cannot express.
-- Retargeted from grievance_cases (live 0024) and cba_articles (above).
-- -----------------------------------------------------------------------------
create or replace function public.validate_precedent_integrity()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_grievance_tenant uuid;
  v_article_tenant   uuid;
begin
  select tenant_id into v_grievance_tenant
  from public.grievance_cases where id = new.grievance_id;
  select tenant_id into v_article_tenant
  from public.cba_articles where id = new.article_id;

  if v_grievance_tenant is null then
    raise exception 'grievance % not found', new.grievance_id using errcode = 'foreign_key_violation';
  end if;
  if v_article_tenant is null then
    raise exception 'cba_article % not found', new.article_id using errcode = 'foreign_key_violation';
  end if;
  if new.tenant_id is distinct from v_grievance_tenant
     or new.tenant_id is distinct from v_article_tenant then
    raise exception
      'cross-tenant precedent blocked (precedent %, grievance %, article %)',
      new.tenant_id, v_grievance_tenant, v_article_tenant using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_precedent_integrity on public.grievance_precedents;
create trigger trg_precedent_integrity
  before insert or update on public.grievance_precedents
  for each row execute function public.validate_precedent_integrity();

-- =============================================================================
-- 4. Row-Level Security
-- Reconciled: header tenant-match AND is_request_tenant_member() (a steward or
-- admin of the header tenant). SELECT and writes are both member-gated — a
-- steward captures precedents for their own tenant's resolved cases. The header
-- alone never grants access; membership is the database authorization decision.
-- =============================================================================
alter table public.cba_articles         enable row level security;
alter table public.cba_articles         force  row level security;
alter table public.grievance_precedents  enable row level security;
alter table public.grievance_precedents  force  row level security;

-- cba_articles ----------------------------------------------------------------
drop policy if exists cba_articles_select on public.cba_articles;
create policy cba_articles_select on public.cba_articles
  for select to authenticated
  using (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_member());

drop policy if exists cba_articles_write on public.cba_articles;
create policy cba_articles_write on public.cba_articles
  for all to authenticated
  using      (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_member())
  with check (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_member());

-- grievance_precedents --------------------------------------------------------
drop policy if exists precedents_select on public.grievance_precedents;
create policy precedents_select on public.grievance_precedents
  for select to authenticated
  using (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_member());

drop policy if exists precedents_write on public.grievance_precedents;
create policy precedents_write on public.grievance_precedents
  for all to authenticated
  using      (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_member())
  with check (tenant_id = public.get_request_tenant_id() AND public.is_request_tenant_member());

-- =============================================================================
-- 5. Grants
-- =============================================================================
grant select, insert, update, delete on public.cba_articles         to authenticated;
grant select, insert, update, delete on public.grievance_precedents  to authenticated;

-- After applying: NOTIFY pgrst, 'reload schema';
