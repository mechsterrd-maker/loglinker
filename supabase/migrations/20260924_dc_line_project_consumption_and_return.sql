-- Project material costing, part 2:
-- (1) DC/RDC lines tagged to a project feed that project's consumption (per line →
--     per project, so one DC can serve several projects), valued at last bought
--     price. Isolated so a costing hiccup never blocks the stock deduction.
-- (2) return_material_from_project(): RDC-closure credit — remaining material and
--     reusable off-cuts come back to stock AND reduce the project's consumed cost
--     (scrap is recorded via the scrap flow and stays a project cost).
CREATE OR REPLACE FUNCTION public.cascade_stock_out_on_dc()
 RETURNS trigger LANGUAGE plpgsql AS $function$
declare
  v_item jsonb; v_qty numeric; v_stock_id uuid; v_ref_prefix text;
  v_txn uuid; v_proj uuid; v_price numeric;
begin
  if new.doc_type::text not in ('dc_out', 'dc_out_returnable') then return new; end if;
  if new.doc_type::text = 'dc_out_returnable'
     and coalesce(new.raw_extraction->>'subcontract_plan_id', '') <> '' then
    return new;
  end if;
  if new.items is null or jsonb_array_length(new.items) = 0 then return new; end if;

  v_ref_prefix := case when new.doc_type::text = 'dc_out_returnable' then 'RDC out: ' else 'DC out: ' end;

  for v_item in select * from jsonb_array_elements(new.items) loop
    v_qty := coalesce((v_item->>'qty')::numeric, 0);
    if v_qty <= 0 then continue; end if;

    v_stock_id := null;
    if (v_item->>'stock_item_id') is not null and (v_item->>'stock_item_id') <> '' then
      begin v_stock_id := (v_item->>'stock_item_id')::uuid; exception when others then v_stock_id := null; end;
      if v_stock_id is not null then
        perform 1 from mcp_stocks_items where id = v_stock_id and plant_id = new.plant_id;
        if not found then v_stock_id := null; end if;
      end if;
    end if;
    if v_stock_id is null then
      v_stock_id := resolve_stock_item_for_line(new.plant_id, new.vendor_id,
        coalesce(v_item->>'name', v_item->>'item_name'), v_item->>'hsn');
    end if;
    if v_stock_id is null then continue; end if;

    insert into mcp_stocks_transactions
      (plant_id, item_id, txn_type, qty, reference, notes, performed_by, document_id)
    values (new.plant_id, v_stock_id, 'issue', v_qty,
      v_ref_prefix || coalesce(new.doc_number, 'no#') || ' · ' || coalesce(new.vendor_name_raw, '?'),
      'Auto from DC ' || new.id, new.created_by, new.id)
    returning id into v_txn;

    -- Project consumption costing (isolated: never block the stock move).
    begin
      v_proj := null;
      if (v_item->>'project_id') ~ '^[0-9a-fA-F-]{36}$' then
        v_proj := (v_item->>'project_id')::uuid;
        if not exists (select 1 from mcp_projects where id = v_proj and plant_id = new.plant_id) then v_proj := null; end if;
      end if;
      if v_proj is not null then
        v_price := public.last_purchase_rate(v_stock_id);
        insert into mcp_project_material_usage
          (plant_id, unit_id, project_id, item_id, item_name, uom, size_spec, unit_weight, qty, total_weight, unit_price, amount, price_source, stock_txn_id, note, created_by)
        select new.plant_id, new.unit_id, v_proj, v_stock_id, si.name, si.uom, si.size_spec, si.unit_weight,
          v_qty, round(coalesce(si.unit_weight,0) * v_qty, 3), v_price, round(v_qty * coalesce(v_price,0), 2),
          case when coalesce(v_price,0) > 0 then 'last_purchase' else 'none' end,
          v_txn, 'From ' || v_ref_prefix || coalesce(new.doc_number,''), new.created_by
        from mcp_stocks_items si where si.id = v_stock_id;
      end if;
    exception when others then null;
    end;
  end loop;

  return new;
exception when others then
  raise warning 'cascade_stock_out_on_dc failed for doc %: %', new.id, sqlerrm;
  return new;
end $function$;

create or replace function public.return_material_from_project(p_project_id uuid, p_item_id uuid, p_qty numeric, p_note text default null, p_price numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_item public.mcp_stocks_items%rowtype; v_price numeric; v_txn uuid; v_usage uuid; v_plant uuid := public.my_plant_id(); v_tw numeric;
begin
  if p_qty is null or p_qty <= 0 then return jsonb_build_object('success', false, 'error', 'Enter a quantity'); end if;
  select * into v_item from public.mcp_stocks_items where id = p_item_id;
  if v_item.id is null or v_item.plant_id is distinct from v_plant then return jsonb_build_object('success', false, 'error', 'No access to that item'); end if;
  if not exists (select 1 from public.mcp_projects where id = p_project_id and plant_id = v_plant) then return jsonb_build_object('success', false, 'error', 'No access to that project'); end if;

  v_price := coalesce(nullif(p_price, 0), public.last_purchase_rate(p_item_id));
  v_tw := round((coalesce(v_item.unit_weight, 0) * p_qty)::numeric, 3);

  insert into public.mcp_stocks_transactions (plant_id, item_id, txn_type, qty, reference, notes, performed_by)
  values (v_plant, p_item_id, 'return', p_qty, 'Returned from project', coalesce(p_note, ''), auth.uid())
  returning id into v_txn;

  insert into public.mcp_project_material_usage
    (plant_id, unit_id, project_id, item_id, item_name, uom, size_spec, unit_weight, qty, total_weight, unit_price, amount, price_source, stock_txn_id, note, created_by)
  values
    (v_plant, v_item.unit_id, p_project_id, p_item_id, v_item.name, v_item.uom, v_item.size_spec, v_item.unit_weight,
     -p_qty, -v_tw, v_price, -round((p_qty * coalesce(v_price,0))::numeric, 2), 'return', v_txn, p_note, auth.uid())
  returning id into v_usage;

  return jsonb_build_object('success', true, 'id', v_usage, 'unit_price', v_price);
exception when others then return jsonb_build_object('success', false, 'error', sqlerrm);
end $$;
grant execute on function public.return_material_from_project(uuid, uuid, numeric, text, numeric) to authenticated;
