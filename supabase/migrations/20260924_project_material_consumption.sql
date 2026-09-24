-- Consumption-based project costing: the real project material cost is what was
-- actually pulled for the project, valued at the item's LAST BOUGHT price (latest
-- GRN rate). Buying excess for stock / future projects no longer inflates a
-- project — only issued material is charged.

create table if not exists public.mcp_project_material_usage (
  id uuid primary key default gen_random_uuid(),
  plant_id uuid not null,
  unit_id uuid,
  project_id uuid not null,
  item_id uuid not null,
  item_name text,
  uom text,
  size_spec text,
  unit_weight numeric,
  qty numeric not null,
  total_weight numeric,
  unit_price numeric,           -- last bought price (per uom) locked at issue time
  amount numeric,               -- qty * unit_price
  price_source text,            -- 'last_purchase' | 'item_cost' | 'manual' | 'none'
  stock_txn_id uuid,
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  reversed_at timestamptz,
  reversed_by uuid
);
create index if not exists idx_pmu_project on public.mcp_project_material_usage(project_id);
create index if not exists idx_pmu_plant on public.mcp_project_material_usage(plant_id);
alter table public.mcp_project_material_usage enable row level security;
do $$ begin
  create policy pmu_select on public.mcp_project_material_usage for select using (plant_id = public.my_plant_id());
exception when duplicate_object then null; end $$;

-- Last bought price for a stock item = most recent GRN line rate (fallbacks:
-- GRN unit_price, item unit_cost, rate_per_kg × unit_weight).
create or replace function public.last_purchase_rate(p_item_id uuid)
returns numeric language sql stable as $$
  select coalesce(
    (select l.rate       from mcp_logistics_grn_lines l where l.stock_item_id = p_item_id and coalesce(l.rate,0) > 0       order by l.created_at desc limit 1),
    (select l.unit_price from mcp_logistics_grn_lines l where l.stock_item_id = p_item_id and coalesce(l.unit_price,0) > 0 order by l.created_at desc limit 1),
    (select i.unit_cost  from mcp_stocks_items i where i.id = p_item_id and coalesce(i.unit_cost,0) > 0),
    (select i.rate_per_kg * coalesce(i.unit_weight,0) from mcp_stocks_items i where i.id = p_item_id and coalesce(i.rate_per_kg,0) > 0),
    0
  );
$$;

-- Pull material for a project: deduct stock as 'consumption' and log the costed
-- line at the last bought price (or an explicit p_price override). Atomic.
create or replace function public.issue_material_to_project(p_project_id uuid, p_item_id uuid, p_qty numeric, p_note text default null, p_price numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_item public.mcp_stocks_items%rowtype; v_price numeric; v_src text;
        v_txn uuid; v_usage uuid; v_plant uuid := public.my_plant_id(); v_amount numeric; v_tw numeric;
begin
  if p_qty is null or p_qty <= 0 then return jsonb_build_object('success', false, 'error', 'Enter a quantity'); end if;
  select * into v_item from public.mcp_stocks_items where id = p_item_id;
  if v_item.id is null or v_item.plant_id is distinct from v_plant then return jsonb_build_object('success', false, 'error', 'No access to that item'); end if;
  if not exists (select 1 from public.mcp_projects where id = p_project_id and plant_id = v_plant) then return jsonb_build_object('success', false, 'error', 'No access to that project'); end if;

  if p_price is not null and p_price > 0 then
    v_price := p_price; v_src := 'manual';
  else
    v_price := public.last_purchase_rate(p_item_id);
    v_src := case
      when exists(select 1 from public.mcp_logistics_grn_lines l where l.stock_item_id = p_item_id and coalesce(l.rate, l.unit_price, 0) > 0) then 'last_purchase'
      when coalesce(v_item.unit_cost, 0) > 0 or coalesce(v_item.rate_per_kg,0) > 0 then 'item_cost'
      else 'none' end;
  end if;
  v_tw := round((coalesce(v_item.unit_weight, 0) * p_qty)::numeric, 3);
  v_amount := round((p_qty * coalesce(v_price, 0))::numeric, 2);

  insert into public.mcp_stocks_transactions (plant_id, item_id, txn_type, qty, reference, notes, performed_by)
  values (v_plant, p_item_id, 'consumption', p_qty, 'Consumed for project', coalesce(p_note, ''), auth.uid())
  returning id into v_txn;

  insert into public.mcp_project_material_usage
    (plant_id, unit_id, project_id, item_id, item_name, uom, size_spec, unit_weight, qty, total_weight, unit_price, amount, price_source, stock_txn_id, note, created_by)
  values
    (v_plant, v_item.unit_id, p_project_id, p_item_id, v_item.name, v_item.uom, v_item.size_spec, v_item.unit_weight, p_qty, v_tw, v_price, v_amount, v_src, v_txn, p_note, auth.uid())
  returning id into v_usage;

  return jsonb_build_object('success', true, 'id', v_usage, 'unit_price', v_price, 'amount', v_amount, 'total_weight', v_tw, 'price_source', v_src);
exception when others then return jsonb_build_object('success', false, 'error', sqlerrm);
end $$;

-- Undo a usage line: credit the stock back and mark the line reversed.
create or replace function public.reverse_project_material_usage(p_usage_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_u public.mcp_project_material_usage%rowtype; v_plant uuid := public.my_plant_id();
begin
  select * into v_u from public.mcp_project_material_usage where id = p_usage_id;
  if v_u.id is null or v_u.plant_id is distinct from v_plant then return jsonb_build_object('success', false, 'error', 'No access'); end if;
  if v_u.reversed_at is not null then return jsonb_build_object('success', true, 'already', true); end if;
  insert into public.mcp_stocks_transactions (plant_id, item_id, txn_type, qty, reference, notes, performed_by)
  values (v_plant, v_u.item_id, 'return', v_u.qty, 'Reversed project consumption', 'Undo of usage ' || v_u.id, auth.uid());
  update public.mcp_project_material_usage set reversed_at = now(), reversed_by = auth.uid() where id = p_usage_id;
  return jsonb_build_object('success', true);
exception when others then return jsonb_build_object('success', false, 'error', sqlerrm);
end $$;

grant execute on function public.last_purchase_rate(uuid) to authenticated;
grant execute on function public.issue_material_to_project(uuid, uuid, numeric, text, numeric) to authenticated;
grant execute on function public.reverse_project_material_usage(uuid) to authenticated;
grant select on public.mcp_project_material_usage to authenticated;
