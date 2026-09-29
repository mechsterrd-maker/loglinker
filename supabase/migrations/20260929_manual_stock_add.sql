-- Allow a document-free MANUAL ADD to stock (adjustment_in) for any user, with
-- no reason note required. Manual reductions (adjustment_out) stay restricted to
-- admin/plant_head with a reason; issue/consumption/scrap and document receipts
-- are unchanged; grn/jobwork_in still require a document.
CREATE OR REPLACE FUNCTION public.trg_enforce_stocks_discipline()
 RETURNS trigger LANGUAGE plpgsql
AS $function$
DECLARE
  v_opened BOOLEAN;
  v_role user_role;
BEGIN
  IF pg_trigger_depth() > 1 THEN RETURN NEW; END IF;

  SELECT opening_recorded_at IS NOT NULL INTO v_opened
    FROM mcp_stocks_items WHERE id = NEW.item_id;

  IF NEW.txn_type = 'opening' THEN
    IF v_opened THEN
      RAISE EXCEPTION 'Opening balance already recorded for this item. After opening, add stock via a document or a manual add (adjustment).'
        USING ERRCODE = '23514';
    END IF;
    UPDATE mcp_stocks_items SET opening_recorded_at = COALESCE(opening_recorded_at, now()) WHERE id = NEW.item_id;
    RETURN NEW;
  END IF;

  IF NOT v_opened THEN
    IF NEW.document_id IS NOT NULL OR NEW.jobwork_line_id IS NOT NULL
       OR NEW.txn_type IN ('issue','consumption','scrap','return','adjustment_in') THEN
      UPDATE mcp_stocks_items SET opening_recorded_at = COALESCE(opening_recorded_at, now()) WHERE id = NEW.item_id;
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'No opening balance recorded for this item. Create an opening entry first (qty can be 0), or receive via a document.'
      USING ERRCODE = '23514';
  END IF;

  -- Manual ADD (adjustment_in): any user, no document, no reason note.
  IF NEW.txn_type = 'adjustment_in' THEN
    RETURN NEW;
  END IF;

  -- Manual REMOVAL (adjustment_out): restricted to admin / plant_head + a reason.
  IF NEW.txn_type = 'adjustment_out' THEN
    SELECT u.role INTO v_role FROM users u WHERE u.id = NEW.performed_by;
    IF v_role NOT IN ('admin'::user_role, 'plant_head'::user_role) THEN
      RAISE EXCEPTION 'Manual stock reduction (adjustment) needs admin or plant_head. Use Issue / Consumption / Scrap instead.' USING ERRCODE = '42501';
    END IF;
    IF NEW.notes IS NULL OR length(trim(NEW.notes)) < 3 THEN
      RAISE EXCEPTION 'Adjustment-out entries require a reason in notes.' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  -- Manual outward and returns of previously-issued material: no document needed.
  IF NEW.txn_type IN ('issue','consumption','scrap','return') THEN
    RETURN NEW;
  END IF;

  -- Remaining INWARD types (grn / jobwork_in): still require a document.
  IF NEW.document_id IS NULL AND NEW.jobwork_line_id IS NULL THEN
    RAISE EXCEPTION 'Received stock must come through a document (vendor bill, DC, job-work return), or use a manual add.'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END $function$;
