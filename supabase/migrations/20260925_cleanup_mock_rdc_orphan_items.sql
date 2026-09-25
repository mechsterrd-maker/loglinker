-- One-off data cleanup: 5 empty stock items left over from a deleted mock RDC
-- (0 qty, 0 transactions, no GRN/project references). Pure test orphans.
-- The delete-doc RPC change in 20260925_delete_doc_cleans_orphan_items.sql stops
-- this from happening again.
delete from public.mcp_stocks_items i
where i.id in (
  '147bc073-caaf-418e-818a-07bc66d101e0',
  'ff140502-224a-4528-828f-4ccec4caf16b',
  'b85edb8e-3cfc-4b4c-a494-56c46ed6e7c2',
  '1fbd5bfe-7f5e-484f-bd04-5c62410be272',
  '738eb2b9-72fd-4787-96a3-200ace9ab2f4'
)
and not exists (select 1 from public.mcp_stocks_transactions t where t.item_id = i.id)
and coalesce(i.current_qty, 0) = 0;
