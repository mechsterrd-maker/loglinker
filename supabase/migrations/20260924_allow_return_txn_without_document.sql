-- A 'return' is material coming back from a prior issue (undo an issue, RDC-closure
-- remaining/off-cuts, offcut returns) — backed by that issue, not a purchase
-- document. It was lumped with grn/jobwork_in and required a document_id, which
-- blocked reverse_project_material_usage and return_material_from_project
-- ("couldn't undo"). Allow 'return' without a document.
CREATE OR REPLACE FUNCTION public.trg_enforce_stocks_discipline()
 RETURNS trigger LANGUAGE plpgsql AS $function$
DECLARE
  v_opened BOOLEAN;
  v_role user_role;
BEGIN
  IF pg_trigger_depth() > 1 THEN RETURN NEW; END IF;
  SELECT opening_recorded_at IS NOT NULL INTO v_opened FROM mcp_stocks_items WHERE id = NEW.item_id;
  IF NEW.txn_type = 'opening' THEN
    IF v_opened THEN RAISE EXCEPTION 'Opening balance already recorded for this item. After opening, all entries must come through a document (vendor bill, DC, job-work) or be an admin adjustment.' USING ERRCODE = '23514'; END IF;
    UPDATE mcp_stocks_items SET opening_recorded_at = COALESCE(opening_recorded_at, now()) WHERE id = NEW.item_id;
    RETURN NEW;
  END IF;
  IF NOT v_opened THEN
    IF NEW.document_id IS NOT NULL OR NEW.jobwork_line_id IS NOT NULL THEN
      UPDATE mcp_stocks_items SET opening_recorded_at = COALESCE(opening_recorded_at, now()) WHERE id = NEW.item_id; RETURN NEW;
    END IF;
    IF NEW.txn_type IN ('issue','consumption','scrap','return') THEN
      UPDATE mcp_stocks_items SET opening_recorded_at = COALESCE(opening_recorded_at, now()) WHERE id = NEW.item_id; RETURN NEW;
    END IF;
    RAISE EXCEPTION 'No opening balance recorded for this item. Create an opening entry first (qty can be 0 if you have none on hand), or receive via a document.' USING ERRCODE = '23514';
  END IF;
  IF NEW.txn_type IN ('adjustment_in','adjustment_out') THEN
    SELECT u.role INTO v_role FROM users u WHERE u.id = NEW.performed_by;
    IF v_role NOT IN ('admin'::user_role, 'plant_head'::user_role) THEN RAISE EXCEPTION 'Stock adjustments require admin or plant_head role.' USING ERRCODE = '42501'; END IF;
    IF NEW.notes IS NULL OR length(trim(NEW.notes)) < 3 THEN RAISE EXCEPTION 'Adjustment entries require a reason in notes.' USING ERRCODE = '23514'; END IF;
    RETURN NEW;
  END IF;
  -- Manual OUTWARD and RETURNS of previously-issued material need no purchase document.
  IF NEW.txn_type IN ('issue','consumption','scrap','return') THEN RETURN NEW; END IF;
  -- Remaining INWARD (grn / jobwork_in) still require a document.
  IF NEW.document_id IS NULL AND NEW.jobwork_line_id IS NULL THEN
    RAISE EXCEPTION 'Received stock must come through a document (vendor bill, DC, job-work return) or an admin adjustment with notes.' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $function$;
