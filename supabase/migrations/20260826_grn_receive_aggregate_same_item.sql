-- verify_and_receive_grn: several receipt lines can map to the SAME stock item
-- (e.g. different plate sizes all credited to "Plate"). The old per-line stock-txn
-- insert then violated uniq_stock_txn_grn_doc_item (unique on document_id,item_id),
-- so the whole receive failed with "duplicate key value violates unique constraint".
-- Fix: update lines + raise shortages per line as before, but post stock as ONE
-- transaction per item with the summed received qty (INSERT ... SELECT GROUP BY item).
CREATE OR REPLACE FUNCTION public.verify_and_receive_grn(p_grn_id uuid, p_line_receipts jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_grn RECORD;
  v_user_id UUID := auth.uid();
  v_lr JSONB;
  v_line RECORD;
  v_received NUMERIC;
  v_item_id UUID;
  v_lines_processed INT := 0;
  v_shortages INT := 0;
  v_shortage_qty NUMERIC;
  v_shortage_value NUMERIC;
  v_buyer UUID;
  v_item_label TEXT;
BEGIN
  IF v_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Not authenticated'); END IF;

  SELECT * INTO v_grn FROM mcp_logistics_grn_receptions WHERE id = p_grn_id;
  IF v_grn IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'GRN not found'); END IF;
  IF v_grn.status <> 'pending_verification' THEN
    RETURN jsonb_build_object('success', false, 'error', 'GRN already ' || v_grn.status);
  END IF;

  SELECT id INTO v_buyer FROM users
    WHERE plant_id = v_grn.plant_id
      AND role IN ('admin'::user_role, 'plant_head'::user_role)
      AND COALESCE(status,'active') = 'active'
    ORDER BY CASE role::text WHEN 'admin' THEN 1 ELSE 2 END, created_at
    LIMIT 1;

  FOR v_lr IN SELECT * FROM jsonb_array_elements(p_line_receipts)
  LOOP
    SELECT * INTO v_line FROM mcp_logistics_grn_lines WHERE id = (v_lr->>'line_id')::UUID;
    CONTINUE WHEN v_line IS NULL;

    v_received := COALESCE(NULLIF(v_lr->>'received_qty', '')::NUMERIC, v_line.doc_qty, 0);
    v_item_id  := COALESCE(NULLIF(v_lr->>'item_id', '')::UUID, v_line.item_id);

    UPDATE mcp_logistics_grn_lines
    SET received_qty = v_received, item_id = v_item_id
    WHERE id = v_line.id;

    IF v_line.doc_qty IS NOT NULL AND v_received < v_line.doc_qty AND v_received >= 0 THEN
      v_shortage_qty := v_line.doc_qty - v_received;
      v_shortage_value := COALESCE(v_line.unit_price, 0) * v_shortage_qty;
      v_item_label := COALESCE(v_line.item_name_raw,
        (SELECT name FROM mcp_stocks_items WHERE id = v_item_id), 'item');

      INSERT INTO actions (
        plant_id, source_type, source_id, source_label, title, description,
        owner_id, department, status, assigned_by, due_at
      ) VALUES (
        v_grn.plant_id, 'grn_shortage'::action_source, v_line.id, 'GRN shortage',
        '📉 Shortage: ' || COALESCE(v_grn.vendor_name, '?')
          || ' · ' || v_shortage_qty::text || ' ' || COALESCE(v_line.uom, '')
          || ' of ' || v_item_label
          || ' on ' || COALESCE(v_grn.reference_no, 'no#')
          || CASE WHEN v_shortage_value > 0 THEN ' · ₹' || round(v_shortage_value)::text ELSE '' END,
        'Doc qty: ' || v_line.doc_qty || ' ' || COALESCE(v_line.uom, '') || E'\n' ||
        'Received: ' || v_received || ' ' || COALESCE(v_line.uom, '') || E'\n' ||
        'Short by: ' || v_shortage_qty || ' ' || COALESCE(v_line.uom, '') ||
          CASE WHEN v_shortage_value > 0 THEN ' (~₹' || round(v_shortage_value)::text || ' value)' ELSE '' END || E'\n\n' ||
        'Follow up with ' || COALESCE(v_grn.vendor_name, 'vendor') || ' — debit note, replacement shipment, or close out as written-off / accepted variance.',
        v_buyer, 'Logistics', 'open', v_user_id, now() + interval '3 days'
      );
      v_shortages := v_shortages + 1;
    END IF;

    v_lines_processed := v_lines_processed + 1;
  END LOOP;

  -- Post stock as ONE transaction per item (summed), so several lines that
  -- credit the same stock item don't collide on uniq_stock_txn_grn_doc_item.
  INSERT INTO mcp_stocks_transactions (
    plant_id, item_id, txn_type, qty, reference, notes, performed_by, document_id
  )
  SELECT v_grn.plant_id, l.item_id, 'grn'::stock_txn_type, SUM(l.received_qty),
    'GRN: ' || COALESCE(v_grn.reference_no, '-'),
    'Received from ' || COALESCE(v_grn.vendor_name, 'vendor'),
    v_user_id, v_grn.document_id
  FROM mcp_logistics_grn_lines l
  WHERE l.grn_id = p_grn_id AND l.item_id IS NOT NULL AND COALESCE(l.received_qty, 0) > 0
  GROUP BY l.item_id;

  UPDATE mcp_logistics_grn_receptions
  SET status = 'received', verified_by = v_user_id, verified_at = now()
  WHERE id = p_grn_id;

  RETURN jsonb_build_object(
    'success', true,
    'lines_processed', v_lines_processed,
    'shortage_tasks_raised', v_shortages
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END $function$;
