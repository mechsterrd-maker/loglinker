-- Cancelling or deleting a DC now also revokes the project consumption it created
-- (previously stock was reversed but the project expense was left behind).
alter table public.mcp_project_material_usage add column if not exists document_id uuid;
create index if not exists idx_pmu_document on public.mcp_project_material_usage(document_id);

update public.mcp_project_material_usage u
  set document_id = t.document_id
  from public.mcp_stocks_transactions t
  where t.id = u.stock_txn_id and u.document_id is null and t.document_id is not null;

-- cascade_stock_out_on_dc now stamps document_id on the consumption rows it creates
-- (see 20260924_dc_line_project_consumption_and_return.sql for the base function;
-- this migration adds `document_id` to that INSERT).
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

    begin
      v_proj := null;
      if (v_item->>'project_id') ~ '^[0-9a-fA-F-]{36}$' then
        v_proj := (v_item->>'project_id')::uuid;
        if not exists (select 1 from mcp_projects where id = v_proj and plant_id = new.plant_id) then v_proj := null; end if;
      end if;
      if v_proj is not null then
        v_price := public.last_purchase_rate(v_stock_id);
        insert into mcp_project_material_usage
          (plant_id, unit_id, project_id, item_id, item_name, uom, size_spec, unit_weight, qty, total_weight, unit_price, amount, price_source, stock_txn_id, document_id, note, created_by)
        select new.plant_id, new.unit_id, v_proj, v_stock_id, si.name, si.uom, si.size_spec, si.unit_weight,
          v_qty, round(coalesce(si.unit_weight,0) * v_qty, 3), v_price, round(v_qty * coalesce(v_price,0), 2),
          case when coalesce(v_price,0) > 0 then 'last_purchase' else 'none' end,
          v_txn, new.id, 'From ' || v_ref_prefix || coalesce(new.doc_number,''), new.created_by
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

-- Cancel DC now revokes the project consumption it created (added the pmu DELETE).
CREATE OR REPLACE FUNCTION public.cancel_logistics_document(p_doc_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_doc mcp_logistics_documents%ROWTYPE;
  v_uid uuid := auth.uid();
  v_role user_role;
BEGIN
  SELECT * INTO v_doc FROM mcp_logistics_documents WHERE id = p_doc_id;
  IF v_doc.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Document not found'); END IF;
  IF v_doc.plant_id <> my_plant_id() THEN RETURN jsonb_build_object('success', false, 'error', 'Not your plant'); END IF;
  IF v_doc.status = 'cancelled' THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;

  SELECT role INTO v_role FROM users WHERE id = v_uid;
  IF NOT (v_role IN ('admin'::user_role, 'plant_head'::user_role)
          OR (v_doc.created_by = v_uid AND v_doc.created_at > now() - interval '24 hours')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'You can cancel a document only within 24 hours of creating it, or as an admin / plant head.');
  END IF;

  DELETE FROM mcp_project_material_usage    WHERE document_id = p_doc_id;
  DELETE FROM mcp_stocks_transactions       WHERE document_id = p_doc_id;
  DELETE FROM mcp_logistics_grn_lines       WHERE doc_id = p_doc_id;
  DELETE FROM mcp_logistics_grn_receptions  WHERE doc_id = p_doc_id OR document_id = p_doc_id;
  DELETE FROM mcp_logistics_jobwork_lines   WHERE doc_id = p_doc_id;
  DELETE FROM mcp_rdc_lines                 WHERE doc_id = p_doc_id;
  DELETE FROM mcp_sched_supplies            WHERE source_doc_id = p_doc_id;

  UPDATE mcp_logistics_documents
  SET status = 'cancelled',
      raw_extraction = COALESCE(raw_extraction, '{}'::jsonb)
                       || jsonb_build_object('cancelled_at', now(), 'cancelled_by', v_uid)
  WHERE id = p_doc_id;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END $function$;

-- Permanent delete that fully reverses (stock + consumption + tracking) and removes
-- the document row.
create or replace function public.delete_logistics_document(p_doc_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_doc mcp_logistics_documents%rowtype;
  v_uid uuid := auth.uid();
  v_role user_role;
begin
  select * into v_doc from mcp_logistics_documents where id = p_doc_id;
  if v_doc.id is null then return jsonb_build_object('success', true, 'already', true); end if;
  if v_doc.plant_id <> my_plant_id() then return jsonb_build_object('success', false, 'error', 'Not your plant'); end if;

  select role into v_role from users where id = v_uid;
  if not (v_role in ('admin'::user_role, 'plant_head'::user_role)
          or (v_doc.created_by = v_uid and v_doc.created_at > now() - interval '24 hours')) then
    return jsonb_build_object('success', false, 'error', 'You can delete a document only within 24 hours of creating it, or as an admin / plant head.');
  end if;

  delete from mcp_project_material_usage    where document_id = p_doc_id;
  delete from mcp_stocks_transactions       where document_id = p_doc_id;
  delete from mcp_logistics_grn_lines       where doc_id = p_doc_id;
  delete from mcp_logistics_grn_receptions  where doc_id = p_doc_id or document_id = p_doc_id;
  delete from mcp_logistics_jobwork_lines   where doc_id = p_doc_id;
  delete from mcp_rdc_lines                 where doc_id = p_doc_id;
  delete from mcp_sched_supplies            where source_doc_id = p_doc_id;
  delete from mcp_logistics_documents       where id = p_doc_id;

  return jsonb_build_object('success', true);
exception when others then return jsonb_build_object('success', false, 'error', sqlerrm);
end $function$;
grant execute on function public.delete_logistics_document(uuid) to authenticated;