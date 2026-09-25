-- UOM + weight-based valuation for per-line bill receiving.
-- Steel is often billed by metric tonne (mtn) or kg. Weight (kg) is the universal
-- anchor: unit_cost = rate_per_kg × unit_weight, so a line values the same in any
-- stock UOM. The builder passes uom, qty, unit_weight (kg/unit), rate_per_kg (₹/kg),
-- unit_cost and pieces; this posts the GRN and stamps the line. Supersedes the
-- bodies in 20260925_receive_bill_line_per_line.sql.
create or replace function public.receive_bill_line(p_doc_id uuid, p_idx int, p_line jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_plant uuid := my_plant_id();
  v_uid uuid := auth.uid();
  v_doc mcp_logistics_documents%rowtype;
  v_items jsonb; v_it jsonb; v_kind text;
  v_stock uuid; v_grn uuid; v_txn uuid;
  v_name text; v_cat text; v_mat text; v_sec text; v_uom text;
  v_qty numeric; v_uw numeric; v_rpk numeric; v_ucost numeric; v_pieces numeric;
  v_proj uuid; v_ctype text; v_code text; v_all_done boolean;
begin
  select * into v_doc from mcp_logistics_documents where id = p_doc_id;
  if v_doc.id is null then return jsonb_build_object('success', false, 'error', 'Document not found'); end if;
  if v_doc.plant_id <> v_plant then return jsonb_build_object('success', false, 'error', 'Not your plant'); end if;
  v_items := coalesce(v_doc.items, '[]'::jsonb);
  if p_idx < 0 or p_idx >= jsonb_array_length(v_items) then return jsonb_build_object('success', false, 'error', 'Bad line index'); end if;
  v_it := v_items -> p_idx;

  v_kind  := coalesce(p_line->>'kind', 'stock');
  v_name  := coalesce(nullif(btrim(p_line->>'name'), ''), v_it->>'name', v_it->>'item_name', 'Item');
  v_cat   := coalesce(nullif(p_line->>'category', ''), 'raw_material');
  v_mat   := nullif(p_line->>'material', '');
  v_sec   := nullif(p_line->>'section', '');
  v_uom   := coalesce(nullif(p_line->>'uom', ''), 'nos');
  v_qty   := coalesce((p_line->>'qty')::numeric, (v_it->>'qty')::numeric, 0);
  v_uw    := nullif(p_line->>'unit_weight', '')::numeric;
  v_rpk   := nullif(p_line->>'rate_per_kg', '')::numeric;
  v_ucost := nullif(p_line->>'unit_cost', '')::numeric;
  v_pieces:= nullif(p_line->>'pieces', '')::numeric;
  v_ctype := nullif(p_line->>'cost_type', '');
  begin v_proj := nullif(p_line->>'project_id', '')::uuid; exception when others then v_proj := null; end;
  if v_proj is not null and not exists (select 1 from mcp_projects where id = v_proj and plant_id = v_plant) then v_proj := null; end if;

  if v_kind = 'stock' then
    if coalesce(v_qty, 0) <= 0 then return jsonb_build_object('success', false, 'error', 'Enter a quantity'); end if;
    if v_ucost is null then
      v_ucost := case when v_rpk is not null and v_uw is not null then round(v_rpk * v_uw, 4)
                      else nullif((v_it->>'rate')::numeric, 0) end;
    end if;

    select id into v_stock from mcp_stocks_items
      where plant_id = v_plant and category = v_cat and lower(name) = lower(v_name)
        and coalesce(unit_id, '00000000-0000-0000-0000-000000000000'::uuid)
            = coalesce(v_doc.unit_id, '00000000-0000-0000-0000-000000000000'::uuid)
      limit 1;
    if v_stock is null then
      v_code := upper(coalesce(nullif(regexp_replace(v_name, '[^A-Za-z0-9]+', '', 'g'), ''), 'ITEM'));
      v_code := (case v_cat when 'raw_material' then 'RM' when 'tools' then 'TL' when 'consumable' then 'CN' else 'GN' end)
                || '-' || left(v_code, 10) || '-' || upper(substr(md5(v_name || p_doc_id::text || p_idx::text), 1, 4));
      insert into mcp_stocks_items (plant_id, unit_id, code, name, category, uom, current_qty, opening_qty, opening_recorded_at, material, section_type, unit_weight, rate_per_kg, unit_cost)
      values (v_plant, v_doc.unit_id, v_code, v_name, v_cat, v_uom, 0, 0, now(), v_mat, v_sec, v_uw, v_rpk, v_ucost)
      returning id into v_stock;
    else
      update mcp_stocks_items set
        uom = coalesce(v_uom, uom), unit_weight = coalesce(v_uw, unit_weight),
        rate_per_kg = coalesce(v_rpk, rate_per_kg), unit_cost = coalesce(v_ucost, unit_cost),
        material = coalesce(material, v_mat), section_type = coalesce(section_type, v_sec)
      where id = v_stock;
    end if;

    select id into v_grn from mcp_logistics_grn_receptions where document_id = p_doc_id or doc_id = p_doc_id limit 1;
    if v_grn is null then
      insert into mcp_logistics_grn_receptions (plant_id, doc_id, document_id, vendor_id, vendor_name, reference_no, reception_date, status, received_by)
      values (v_plant, p_doc_id, p_doc_id, v_doc.vendor_id,
        coalesce(v_doc.vendor_name_raw, (select name from mcp_logistics_vendors where id = v_doc.vendor_id)),
        v_doc.doc_number, coalesce(v_doc.doc_date, current_date), 'pending_verification', v_uid)
      returning id into v_grn;
    end if;

    insert into mcp_stocks_transactions (plant_id, item_id, txn_type, qty, reference, notes, performed_by, document_id)
    values (v_plant, v_stock, 'grn', v_qty,
      'GRN: ' || coalesce(v_doc.doc_number, 'no#') || ' · ' || coalesce(v_doc.vendor_name_raw, '?'),
      'Received per-line from bill' || case when v_pieces is not null then ' · ' || v_pieces || ' pcs' else '' end,
      v_uid, p_doc_id)
    returning id into v_txn;

    insert into mcp_logistics_grn_lines (plant_id, grn_id, doc_id, stock_item_id, item_id, vendor_item_name, item_name_raw, doc_qty, invoice_qty, received_qty, rejected_qty, rate, unit_price, uom, txn_id)
    values (v_plant, v_grn, p_doc_id, v_stock, v_stock, v_name, v_name, v_qty, v_qty, v_qty, 0, coalesce(v_ucost,0), coalesce(v_ucost,0), v_uom, v_txn);

    v_it := v_it || jsonb_build_object('_rcv', 'stock', 'stock_item_id', v_stock, 'dest', v_cat, 'received_qty', v_qty, 'received_uom', v_uom, 'pieces', v_pieces, 'project_id', v_proj, 'cost_type', v_ctype);
  elsif v_kind = 'charge' then
    v_it := v_it || jsonb_build_object('_rcv', 'charge', 'cost_type', coalesce(v_ctype, 'transport'), 'project_id', v_proj);
  else
    v_it := v_it || jsonb_build_object('_rcv', 'skip');
  end if;

  v_items := jsonb_set(v_items, array[p_idx::text], v_it);
  select bool_and((e->>'_rcv') is not null) into v_all_done from jsonb_array_elements(v_items) e;
  update mcp_logistics_documents set items = v_items, project_id = coalesce(project_id, v_proj) where id = p_doc_id;
  if v_all_done then
    update mcp_logistics_grn_receptions set status = 'received', verified_by = v_uid, verified_at = now()
      where (document_id = p_doc_id or doc_id = p_doc_id) and status <> 'received';
  end if;
  return jsonb_build_object('success', true, 'all_done', coalesce(v_all_done, false), 'stock_item', v_stock);
exception when others then return jsonb_build_object('success', false, 'error', sqlerrm);
end $$;
grant execute on function public.receive_bill_line(uuid, int, jsonb) to authenticated;

create or replace function public.undo_bill_line(p_doc_id uuid, p_idx int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_plant uuid := my_plant_id();
  v_doc mcp_logistics_documents%rowtype;
  v_items jsonb; v_it jsonb; v_stock uuid;
begin
  select * into v_doc from mcp_logistics_documents where id = p_doc_id;
  if v_doc.id is null then return jsonb_build_object('success', false, 'error', 'Document not found'); end if;
  if v_doc.plant_id <> v_plant then return jsonb_build_object('success', false, 'error', 'Not your plant'); end if;
  v_items := coalesce(v_doc.items, '[]'::jsonb);
  if p_idx < 0 or p_idx >= jsonb_array_length(v_items) then return jsonb_build_object('success', false, 'error', 'Bad line index'); end if;
  v_it := v_items -> p_idx;

  if (v_it->>'_rcv') = 'stock' and (v_it->>'stock_item_id') is not null then
    begin v_stock := (v_it->>'stock_item_id')::uuid; exception when others then v_stock := null; end;
    if v_stock is not null then
      delete from mcp_stocks_transactions
        where id = (select id from mcp_stocks_transactions
                    where document_id = p_doc_id and item_id = v_stock and txn_type = 'grn'
                    order by created_at desc limit 1);
      delete from mcp_logistics_grn_lines
        where doc_id = p_doc_id and stock_item_id = v_stock
          and coalesce(received_qty,0) = coalesce((v_it->>'received_qty')::numeric, received_qty);
    end if;
  end if;

  v_it := (v_it - '_rcv' - 'stock_item_id' - 'received_qty' - 'received_uom' - 'pieces' - 'dest');
  v_items := jsonb_set(v_items, array[p_idx::text], v_it);
  update mcp_logistics_documents set items = v_items where id = p_doc_id;
  update mcp_logistics_grn_receptions set status = 'pending_verification'
    where (document_id = p_doc_id or doc_id = p_doc_id) and status = 'received';
  return jsonb_build_object('success', true);
exception when others then return jsonb_build_object('success', false, 'error', sqlerrm);
end $$;
grant execute on function public.undo_bill_line(uuid, int) to authenticated;
