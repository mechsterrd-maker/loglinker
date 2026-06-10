-- 1D cutting planner: one row per planning exercise. Inputs (stocks, pieces) and
-- output (layout, totals) live as jsonb so the plan is consumed atomically — a
-- supervisor will rarely query "find me bar #3 of plan X" via SQL.
create table public.mcp_cut_plans (
  id uuid primary key default gen_random_uuid(),
  plant_id uuid not null references public.plants(id) on delete cascade,
  project_id uuid references public.mcp_projects(id) on delete set null,
  stage_id uuid references public.mcp_project_milestones(id) on delete set null,
  plan_no text,
  title text not null,
  stock_material text,                     -- free-text label e.g. "MS Round Bar 25mm"
  kerf_mm numeric not null default 3,      -- saw kerf width
  status text not null default 'draft' check (status in ('draft','approved','cut','cancelled')),
  stocks jsonb not null default '[]'::jsonb,   -- [{ id, lengthMm, qty, unitCost }]
  pieces jsonb not null default '[]'::jsonb,   -- [{ id, lengthMm, qty, label }]
  layout jsonb,                                -- [{ stockId, stockLength, cuts:[{label,length}], used, wasteMm }]
  totals jsonb,                                -- { barsUsed, totalStockMm, wasteMm, wastePct, totalCost }
  notes text,
  created_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index mcp_cut_plans_plant_idx       on public.mcp_cut_plans(plant_id);
create index mcp_cut_plans_project_idx     on public.mcp_cut_plans(plant_id, project_id);
create index mcp_cut_plans_stage_idx       on public.mcp_cut_plans(plant_id, stage_id);
create index mcp_cut_plans_created_at_idx  on public.mcp_cut_plans(plant_id, created_at desc);

alter table public.mcp_cut_plans enable row level security;

create policy cut_plans_select on public.mcp_cut_plans
  for select to authenticated
  using (plant_id in (select u.plant_id from public.users u where u.id = auth.uid()));

create policy cut_plans_insert on public.mcp_cut_plans
  for insert to authenticated
  with check (plant_id in (select u.plant_id from public.users u where u.id = auth.uid()));

create policy cut_plans_update on public.mcp_cut_plans
  for update to authenticated
  using (plant_id in (select u.plant_id from public.users u where u.id = auth.uid()))
  with check (plant_id in (select u.plant_id from public.users u where u.id = auth.uid()));

create policy cut_plans_delete on public.mcp_cut_plans
  for delete to authenticated
  using (plant_id in (select u.plant_id from public.users u where u.id = auth.uid()));

create or replace function public.tg_touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists tg_mcp_cut_plans_touch on public.mcp_cut_plans;
create trigger tg_mcp_cut_plans_touch before update on public.mcp_cut_plans
  for each row execute function public.tg_touch_updated_at();
