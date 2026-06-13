-- Honour an explicit stock_item_id in the DC item JSON before falling back
-- to the fuzzy name resolver. The UI now lets the user pick a stock item
-- directly so the deduct can't quietly miss.
create or replace function public.cascade_stock_out_on_dc()
returns trigger
language plpgsql
as $function$
declare
  v_item jsonb;
  v_qty numeric;
  v_stock_id uuid;
begin
  if new.doc_type::text <> 'dc_out' then return new; end if;
  if new.items is null or jsonb_array_length(new.items) = 0 then return new; end if;

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
      'DC out: ' || coalesce(new.doc_number, 'no#') || ' · ' || coalesce(new.vendor_name_raw, '?'),
      'Auto from DC ' || new.id,
      new.created_by, new.id
    );
  end loop;

  return new;
exception when others then
  raise warning 'cascade_stock_out_on_dc failed for doc %: %', new.id, sqlerrm;
  return new;
end $function$;
