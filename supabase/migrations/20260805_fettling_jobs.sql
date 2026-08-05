-- Fettling JOBS master + fixed piece price. Instead of typing the part on every
-- daily row, the plant keeps a short master of fettling jobs, each with its FIXED
-- ₹/piece rate set once (kept separate from the daily plan/done entry). Daily log
-- rows point at a job and snapshot its name + rate at the moment they're chosen, so
-- a later price change never rewrites past payouts.

create table if not exists public.fettling_parts (
  id          uuid primary key default gen_random_uuid(),
  plant_id    uuid not null references public.plants(id) on delete cascade,
  unit_id     uuid references public.units(id) on delete set null,
  name        text not null,
  rate        numeric,                              -- fixed ₹ per piece
  active      boolean not null default true,
  created_by  uuid references public.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists idx_fettling_parts_plant on public.fettling_parts(plant_id, active);

alter table public.fettling_log add column if not exists part_id uuid references public.fettling_parts(id) on delete set null;

-- RLS for the new master (fettling_log already has policies).
do $$
begin
  execute 'alter table public.fettling_parts enable row level security';
  execute 'drop policy if exists fettling_parts_sel on public.fettling_parts';
  execute 'drop policy if exists fettling_parts_ins on public.fettling_parts';
  execute 'drop policy if exists fettling_parts_upd on public.fettling_parts';
  execute 'drop policy if exists fettling_parts_del on public.fettling_parts';
  execute 'drop policy if exists unit_iso on public.fettling_parts';
  execute 'create policy fettling_parts_sel on public.fettling_parts for select to authenticated using (plant_id = my_plant_id())';
  execute 'create policy fettling_parts_ins on public.fettling_parts for insert to authenticated with check (plant_id = my_plant_id())';
  execute 'create policy fettling_parts_upd on public.fettling_parts for update to authenticated using (plant_id = my_plant_id()) with check (plant_id = my_plant_id())';
  execute 'create policy fettling_parts_del on public.fettling_parts for delete to authenticated using (plant_id = my_plant_id())';
  execute 'create policy unit_iso on public.fettling_parts as restrictive for all to authenticated using (public.unit_visible(unit_id)) with check (public.unit_visible(unit_id))';
  execute 'drop trigger if exists trg_set_unit on public.fettling_parts';
  execute 'create trigger trg_set_unit before insert on public.fettling_parts for each row execute function public.set_unit_from_active()';
end $$;
