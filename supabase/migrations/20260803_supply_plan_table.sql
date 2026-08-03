-- The supply plan can put a quantity on ANY part x delivery-date cell, including
-- dates where the customer had no demand line. So it lives in its own table keyed
-- by (schedule, part, date) rather than on the demand line. Migrates any values
-- already entered on mcp_sched_lines.supply_plan_qty.
create table if not exists public.mcp_sched_supply_plan (
  id uuid primary key default gen_random_uuid(),
  plant_id uuid not null references public.plants(id) on delete cascade,
  unit_id uuid references public.units(id) on delete set null,
  schedule_id uuid not null references public.mcp_sched_schedules(id) on delete cascade,
  part_name_raw text not null,
  customer_part_number text not null default '',
  delivery_date date not null,
  plan_qty numeric not null default 0,
  created_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (schedule_id, part_name_raw, customer_part_number, delivery_date)
);
create index if not exists idx_supply_plan_sched on public.mcp_sched_supply_plan(schedule_id);

alter table public.mcp_sched_supply_plan enable row level security;
drop policy if exists mcp_sched_supply_plan_sel on public.mcp_sched_supply_plan;
drop policy if exists mcp_sched_supply_plan_ins on public.mcp_sched_supply_plan;
drop policy if exists mcp_sched_supply_plan_upd on public.mcp_sched_supply_plan;
drop policy if exists mcp_sched_supply_plan_del on public.mcp_sched_supply_plan;
drop policy if exists unit_iso on public.mcp_sched_supply_plan;
create policy mcp_sched_supply_plan_sel on public.mcp_sched_supply_plan for select to authenticated using (plant_id = my_plant_id());
create policy mcp_sched_supply_plan_ins on public.mcp_sched_supply_plan for insert to authenticated with check (plant_id = my_plant_id());
create policy mcp_sched_supply_plan_upd on public.mcp_sched_supply_plan for update to authenticated using (plant_id = my_plant_id()) with check (plant_id = my_plant_id());
create policy mcp_sched_supply_plan_del on public.mcp_sched_supply_plan for delete to authenticated using (plant_id = my_plant_id());
create policy unit_iso on public.mcp_sched_supply_plan as restrictive for all to authenticated using (public.unit_visible(unit_id)) with check (public.unit_visible(unit_id));
drop trigger if exists trg_set_unit on public.mcp_sched_supply_plan;
create trigger trg_set_unit before insert on public.mcp_sched_supply_plan for each row execute function public.set_unit_from_active();

insert into public.mcp_sched_supply_plan (plant_id, unit_id, schedule_id, part_name_raw, customer_part_number, delivery_date, plan_qty)
select l.plant_id, l.unit_id, l.schedule_id, coalesce(l.part_name_raw,'?'), coalesce(l.customer_part_number,''), l.delivery_date, l.supply_plan_qty
from public.mcp_sched_lines l
where l.supply_plan_qty is not null and l.delivery_date is not null
on conflict (schedule_id, part_name_raw, customer_part_number, delivery_date) do nothing;
