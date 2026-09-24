-- Make stock reduce when a Returnable DC (dc_out_returnable) is created, the same
-- way a regular DC (dc_out) already does.
--
-- Bug: cascade_stock_out_on_dc() bailed out unless doc_type = 'dc_out', so a
-- returnable DC made through the general "Create DC" form left stock untouched —
-- the material showed as sent on the challan but never left the stock count.
--
-- Fix: also handle 'dc_out_returnable'. Returnable DCs raised from a subcontract
-- plan already deduct their material (as jobwork_out) inside sc_plan_issue_dc, so
-- those are skipped here (identified by raw_extraction.subcontract_plan_id) to
-- avoid double-counting.
CREATE OR REPLACE FUNCTION public.cascade_stock_out_on_dc()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_item jsonb;
  v_qty numeric;
  v_stock_id uuid;
  v_ref_prefix text;
begin
  if new.doc_type::text not in ('dc_out', 'dc_out_returnable') then return new; end if;
  -- Returnable DCs raised from a subcontract plan already deducted their material
  -- (jobwork_out) inside sc_plan_issue_dc — don't double-deduct them here.
  if new.doc_type::text = 'dc_out_returnable'
     and coalesce(new.raw_extraction->>'subcontract_plan_id', '') <> '' then
    return new;
  end if;
  if new.items is null or jsonb_array_length(new.items) = 0 then return new; end if;

  v_ref_prefix := case when new.doc_type::text = 'dc_out_returnable' then 'RDC out: ' else 'DC out: ' end;

  for v_item in select * from jsonb_array_elements(new.items) loop
    v_qty := coalesce((v_item->>'qty')::numeric, 0);
    if v_qty <= 0 then continue; end if;

    -- 1. explicit pick wins.
    v_stock_id := null;
    if (v_item->>'stock_item_id') is not null and (v_item->>'stock_item_id') <> '' then
      begin
        v_stock_id := (v_item->>'stock_item_id')::uuid;
      exception when others then
        v_stock_id := null;
      end;
      -- Verify the stock item actually belongs to this plant.
      if v_stock_id is not null then
        perform 1 from mcp_stocks_items where id = v_stock_id and plant_id = new.plant_id;
        if not found then v_stock_id := null; end if;
      end if;
    end if;

    -- 2. fall back to alias / name / code resolver (legacy path).
    if v_stock_id is null then
      v_stock_id := resolve_stock_item_for_line(
        new.plant_id, new.vendor_id,
        coalesce(v_item->>'name', v_item->>'item_name'),
        v_item->>'hsn'
      );
    end if;
    if v_stock_id is null then continue; end if;

    insert into mcp_stocks_transactions
      (plant_id, item_id, txn_type, qty, reference, notes, performed_by, document_id)
    values (
      new.plant_id, v_stock_id, 'issue', v_qty,
      v_ref_prefix || coalesce(new.doc_number, 'no#') || ' · ' || coalesce(new.vendor_name_raw, '?'),
      'Auto from DC ' || new.id,
      new.created_by, new.id
    );
  end loop;

  return new;
exception when others then
  raise warning 'cascade_stock_out_on_dc failed for doc %: %', new.id, sqlerrm;
  return new;
end $function$;
