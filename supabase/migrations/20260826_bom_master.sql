-- Bill of Materials master for fabrication. A BOM's OUTPUT is a stock item (a
-- sub-job / finished part); its LINES are the RM stock items it consumes, each with
-- its own unit + scrap %. Consumption to make Q output units =
-- qty_per * (Q / output_qty) * (1 + scrap_pct/100). Reuses the stock master.
create table if not exists public.mcp_bom (
  id uuid primary key default gen_random_uuid(),
  plant_id uuid not null references public.plants(id) on delete cascade,
  unit_id uuid references public.units(id) on delete set null,
  output_item_id uuid not null references public.mcp_stocks_items(id) on delete cascade,
  output_qty numeric not null default 1,
  name text, notes text, active boolean not null default true,
  created_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (plant_id, output_item_id)
);
create index if not exists idx_bom_plant on public.mcp_bom(plant_id, active);

create table if not exists public.mcp_bom_lines (
  id uuid primary key default gen_random_uuid(),
  plant_id uuid not null references public.plants(id) on delete cascade,
  unit_id uuid references public.units(id) on delete set null,
  bom_id uuid not null references public.mcp_bom(id) on delete cascade,
  rm_item_id uuid not null references public.mcp_stocks_items(id) on delete restrict,
  qty_per numeric not null default 0,
  uom text, scrap_pct numeric not null default 0, notes text,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists idx_bom_lines_bom on public.mcp_bom_lines(bom_id);

do $$
declare t text;
begin
  foreach t in array array['mcp_bom','mcp_bom_lines']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t||'_sel', t);
    execute format('drop policy if exists %I on public.%I', t||'_all', t);
    execute format('drop policy if exists unit_iso on public.%I', t);
    execute format('create policy %I on public.%I for select to authenticated using (plant_id = my_plant_id())', t||'_sel', t);
    execute format('create policy %I on public.%I for all to authenticated using (plant_id = my_plant_id()) with check (plant_id = my_plant_id())', t||'_all', t);
    execute format('create policy unit_iso on public.%I as restrictive for all to authenticated using (public.unit_visible(unit_id)) with check (public.unit_visible(unit_id))', t);
    execute format('drop trigger if exists trg_set_unit on public.%I', t);
    execute format('create trigger trg_set_unit before insert on public.%I for each row execute function public.set_unit_from_active()', t);
  end loop;
end $$;

insert into public.role_permissions (role_id, module_key, action)
select pr.id, 'bom', '*' from public.plant_roles pr where pr.is_builtin
on conflict do nothing;
