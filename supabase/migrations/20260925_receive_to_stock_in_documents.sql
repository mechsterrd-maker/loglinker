-- Receiving to stock is now done on the document itself (Documents → open the
-- inward bill/DC → "Receive into stock"), and the separate "Receive from Doc"
-- card in Stocks is removed. The document processor treats a reception as done
-- only when status = 'received'; a 'pending_verification' row means "still to
-- receive" and now shows the receive flow in Documents (with a "To receive"
-- queue tab). This is a UI change (app.html); the only data change is below.
--
-- Six older receptions were left 'pending_verification' even though their GRN
-- stock had already been posted (via the retired picker path). Mark them
-- 'received' so the document shows "already received" and they cannot be posted
-- to stock a second time.
update public.mcp_logistics_grn_receptions r
set status = 'received',
    verified_at = coalesce(r.verified_at, now())
where r.status = 'pending_verification'
  and exists (
    select 1 from public.mcp_stocks_transactions t
    where t.document_id = r.document_id and t.txn_type = 'grn'
  );
