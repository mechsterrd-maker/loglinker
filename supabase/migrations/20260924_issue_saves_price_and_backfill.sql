-- Typed issue price now "loads" onto the item (unit_cost / rate_per_kg) so future
-- DCs and issues value the material automatically; backfill of a returnable DC made
-- in the window before the consumption-costing hook was live. (Applied to the DB;
-- the Alu-Pipe price set and the RDC/0001 row backfill are one-off data corrections
-- and are intentionally omitted from this file — see migration history.)
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
    update public.mcp_stocks_items
      set unit_cost = p_price,
          rate_per_kg = case when coalesce(unit_weight,0) > 0 then round((p_price / unit_weight)::numeric, 4) else rate_per_kg end,
          updated_at = now()
      where id = p_item_id;
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
