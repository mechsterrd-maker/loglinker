-- Per-line receiving from a bill. Each line is saved on its own as either:
--   • stock  — build/match the stock item (material / section / category /
--               pieces / weight) and post a GRN movement, or
--   • charge — transport / loading / freight etc: cost-typed, NOT added to stock, or
--   • skip   — ignored.
-- The line is stamped on the document (items[].{_rcv,...}) so the UI shows it green
-- on reload. When every line is handled, the GRN reception flips to 'received' so
-- the bill leaves the "To receive" queue. undo_bill_line reverses one line.
create or replace function public.receive_bill_line(p_doc_id uuid, p_idx int, p_line jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_plant uuid := my_plant_id();
  v_uid uuid := auth.uid();
  v_doc mcp_logistics_documents%rowtype;
  v_items jsonb; v_it jsonb; v_kind text;
  v_stock uuid; v_grn uuid; v_txn uuid;
  v_name text; v_cat text; v_mat text; v_sec text; v_uom text;
  v_qty numeric; v_uw numeric; v_rate numeric; v_proj uuid; v_ctype text;
  v_code text; v_all_done boolean;
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
  v_uom   := coalesce(nullif(p_line->>'uom', ''), v_it->>'uom', 'nos');
  v_qty   := coalesce((p_line->>'qty')::numeric, (v_it->>'qty')::numeric, 0);
  v_uw    := nullif(p_line->>'unit_weight', '')::numeric;
  v_rate  := coalesce((p_line->>'rate')::numeric, (v_it->>'rate')::numeric, 0);
  v_ctype := nullif(p_line->>'cost_type', '');
  begin v_proj := nullif(p_line->>'project_id', '')::uuid; exception when others then v_proj := null; end;
  if v_proj is not null and not exists (select 1 from mcp_projects where id = v_proj and plant_id = v_plant) then v_proj := null; end if;

  if v_kind = 'stock' then
    if coalesce(v_qty, 0) <= 0 then return jsonb_build_object('success', false, 'error', 'Enter a quantity'); end if;

    select id into v_stock from mcp_stocks_items
      where plant_id = v_plant and category = v_cat and lower(name) = lower(v_name)
        and coalesce(unit_id, '00000000-0000-0000-0000-000000000000'::uuid)
            = coalesce(v_doc.unit_id, '00000000-0000-0000-0000-000000000000'::uuid)
      limit 1;
    if v_stock is null then
      v_code := upper(coalesce(nullif(regexp_replace(v_name, '[^A-Za-z0-9]+', '', 'g'), ''), 'ITEM'));
      v_code := (case v_cat when 'raw_material' then 'RM' when 'tools' then 'TL' when 'consumable' then 'CN' else 'GN' end)
                || '-' || left(v_code, 10) || '-' || upper(substr(md5(v_name || p_doc_id::text || p_idx::text), 1, 4));
      insert into mcp_stocks_items (plant_id, unit_id, code, name, category, uom, current_qty, opening_qty, opening_recorded_at, material, section_type, unit_weight)
      values (v_plant, v_doc.unit_id, v_code, v_name, v_cat, v_uom, 0, 0, now(), v_mat, v_sec, v_uw)
      returning id into v_stock;
    elsif v_uw is not null then
      update mcp_stocks_items set unit_weight = v_uw where id = v_stock and coalesce(unit_weight, 0) = 0;
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
      'Received per-line from bill', v_uid, p_doc_id)
    returning id into v_txn;

    insert into mcp_logistics_grn_lines (plant_id, grn_id, doc_id, stock_item_id, item_id, vendor_item_name, item_name_raw, doc_qty, invoice_qty, received_qty, rejected_qty, rate, unit_price, uom, txn_id)
    values (v_plant, v_grn, p_doc_id, v_stock, v_stock, v_name, v_name, v_qty, v_qty, v_qty, 0, v_rate, v_rate, v_uom, v_txn);

    if v_rate > 0 then
      update mcp_stocks_items
        set unit_cost = v_rate,
            rate_per_kg = case when category = 'raw_material' and lower(v_uom) in ('kg','kgs') then v_rate else rate_per_kg end
        where id = v_stock;
    end if;

    v_it := v_it || jsonb_build_object('_rcv', 'stock', 'stock_item_id', v_stock, 'dest', v_cat, 'received_qty', v_qty, 'project_id', v_proj, 'cost_type', v_ctype);
  elsif v_kind = 'charge' then
    v_it := v_it || jsonb_build_object('_rcv', 'charge', 'cost_type', coalesce(v_ctype, 'transport'), 'project_id', v_proj);
  else
    v_it := v_it || jsonb_build_object('_rcv', 'skip');
  end if;

  v_items := jsonb_set(v_items, array[p_idx::text], v_it);
  select bool_and((e->>'_rcv') is not null) into v_all_done from jsonb_array_elements(v_items) e;

  update mcp_logistics_documents
    set items = v_items, project_id = coalesce(project_id, v_proj)
    where id = p_doc_id;

  if v_all_done then
    update mcp_logistics_grn_receptions
      set status = 'received', verified_by = v_uid, verified_at = now()
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

  v_it := (v_it - '_rcv' - 'stock_item_id' - 'received_qty' - 'dest');
  v_items := jsonb_set(v_items, array[p_idx::text], v_it);
  update mcp_logistics_documents set items = v_items where id = p_doc_id;
  update mcp_logistics_grn_receptions set status = 'pending_verification'
    where (document_id = p_doc_id or doc_id = p_doc_id) and status = 'received';
  return jsonb_build_object('success', true);
exception when others then return jsonb_build_object('success', false, 'error', sqlerrm);
end $$;
grant execute on function public.undo_bill_line(uuid, int) to authenticated;
