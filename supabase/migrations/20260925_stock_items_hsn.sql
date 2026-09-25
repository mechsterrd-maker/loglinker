-- HSN on stock items, so DCs/invoices auto-fill the exact HSN when a stock item
-- is picked. The master is the source of truth; it fills up from:
--   • backfill from document history (below),
--   • the item form's new HSN field,
--   • per-line bill receiving (receive_bill_line saves the bill's HSN), and
--   • making a DC (the app writes the line's HSN back to the item when it has none).
alter table public.mcp_stocks_items add column if not exists hsn text;

update public.mcp_stocks_items si
set hsn = sub.hsn
from (
  select (it->>'stock_item_id')::uuid as sid,
         (array_agg(nullif(btrim(it->>'hsn'), '') order by d.created_at desc))[1] as hsn
  from public.mcp_logistics_documents d
  cross join lateral jsonb_array_elements(coalesce(d.items, '[]'::jsonb)) it
  where (it->>'stock_item_id') ~ '^[0-9a-fA-F-]{36}$'
    and nullif(btrim(it->>'hsn'), '') is not null
  group by (it->>'stock_item_id')::uuid
) sub
where si.id = sub.sid and coalesce(nullif(btrim(si.hsn), ''), '') = '';

update public.mcp_stocks_items si
set hsn = sub.hsn
from (
  select gl.stock_item_id as sid,
         (array_agg(nullif(btrim(it->>'hsn'), '') order by d.created_at desc))[1] as hsn
  from public.mcp_logistics_grn_lines gl
  join public.mcp_logistics_documents d on d.id = gl.doc_id
  cross join lateral jsonb_array_elements(coalesce(d.items, '[]'::jsonb)) it
  where gl.stock_item_id is not null
    and lower(coalesce(it->>'name', it->>'item_name')) = lower(coalesce(gl.item_name_raw, ''))
    and nullif(btrim(it->>'hsn'), '') is not null
  group by gl.stock_item_id
) sub
where si.id = sub.sid and coalesce(nullif(btrim(si.hsn), ''), '') = '';

-- receive_bill_line also stores the bill line's HSN on the item (fill-if-empty).
-- Full body applied in the DB; the change vs 20260925_receive_bill_line_uom_weight.sql
-- is: read v_hsn from the line and set it on the stock item (insert + update).
