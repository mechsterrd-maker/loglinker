-- Fettling contract work — a deliberately simple daily tracker for the handful of
-- contract workers who fettle castings. Two tables: the workers (a short manual
-- list, they usually have no login) and a per-worker per-day log of planned vs
-- done quantity, with an optional piece rate so their contract payout falls out.
-- Plant-scoped + unit-isolated like the rest of the app; frontend inserts omit
-- unit_id (the BEFORE INSERT trigger stamps it from the active unit).

create table if not exists public.fettling_workers (
  id          uuid primary key default gen_random_uuid(),
  plant_id    uuid not null references public.plants(id) on delete cascade,
  unit_id     uuid references public.units(id) on delete set null,
  name        text not null,
  phone       text,
  active      boolean not null default true,
  created_by  uuid references public.users(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists idx_fettling_workers_plant on public.fettling_workers(plant_id, active);

create table if not exists public.fettling_log (
  id          uuid primary key default gen_random_uuid(),
  plant_id    uuid not null references public.plants(id) on delete cascade,
  unit_id     uuid references public.units(id) on delete set null,
  work_date   date not null,
  worker_id   uuid not null references public.fettling_workers(id) on delete cascade,
  part_name   text not null default '',
  planned_qty numeric not null default 0,
  done_qty    numeric not null default 0,
  reject_qty  numeric not null default 0,
  rate        numeric,                              -- optional ₹ per piece (contract payout)
  notes       text,
  created_by  uuid references public.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists idx_fettling_log_date on public.fettling_log(plant_id, work_date, worker_id);

-- RLS: plant-scoped + unit-isolated, same convention as the ppc / tooling modules.
do $$
declare t text;
begin
  foreach t in array array['fettling_workers','fettling_log']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t||'_sel', t);
    execute format('drop policy if exists %I on public.%I', t||'_ins', t);
    execute format('drop policy if exists %I on public.%I', t||'_upd', t);
    execute format('drop policy if exists %I on public.%I', t||'_del', t);
    execute format('drop policy if exists unit_iso on public.%I', t);
    execute format('create policy %I on public.%I for select to authenticated using (plant_id = my_plant_id())', t||'_sel', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (plant_id = my_plant_id())', t||'_ins', t);
    execute format('create policy %I on public.%I for update to authenticated using (plant_id = my_plant_id()) with check (plant_id = my_plant_id())', t||'_upd', t);
    execute format('create policy %I on public.%I for delete to authenticated using (plant_id = my_plant_id())', t||'_del', t);
    execute format('create policy unit_iso on public.%I as restrictive for all to authenticated using (public.unit_visible(unit_id)) with check (public.unit_visible(unit_id))', t);
    execute format('drop trigger if exists trg_set_unit on public.%I', t);
    execute format('create trigger trg_set_unit before insert on public.%I for each row execute function public.set_unit_from_active()', t);
  end loop;
end $$;

-- RBAC: grant the fettling module to every built-in role on existing plants.
insert into public.role_permissions (role_id, module_key, action)
select pr.id, 'fettling', '*'
from public.plant_roles pr
where pr.is_builtin
on conflict do nothing;
