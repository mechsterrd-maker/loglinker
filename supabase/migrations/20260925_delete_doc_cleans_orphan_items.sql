-- When a document is deleted/cancelled, unwind the WHOLE pipeline — including any
-- stock ITEMS that were auto-created while receiving against it (offcuts, cut
-- parts) and are now empty. Previously the transactions were removed and the
-- quantities reversed, but the auto-created item shells were left behind (they
-- lingered in the item list at 0 qty). Now, any item that this document's
-- transactions touched and that ends up with no transactions and no quantity is
-- removed too. Items still used by other documents (they keep transactions) or
-- still referenced elsewhere (guarded per-item) are kept.

CREATE OR REPLACE FUNCTION public.cancel_logistics_document(p_doc_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_doc mcp_logistics_documents%ROWTYPE;
  v_uid uuid := auth.uid();
  v_role user_role;
  v_items uuid[];
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

  SELECT array_agg(DISTINCT item_id) INTO v_items FROM mcp_stocks_transactions WHERE document_id = p_doc_id;

  DELETE FROM mcp_project_material_usage    WHERE document_id = p_doc_id;
  DELETE FROM mcp_stocks_transactions       WHERE document_id = p_doc_id;
  DELETE FROM mcp_rdc_receipts              WHERE doc_id = p_doc_id;
  DELETE FROM mcp_logistics_grn_lines       WHERE doc_id = p_doc_id;
  DELETE FROM mcp_logistics_grn_receptions  WHERE doc_id = p_doc_id OR document_id = p_doc_id;
  DELETE FROM mcp_logistics_jobwork_lines   WHERE doc_id = p_doc_id;
  DELETE FROM mcp_rdc_lines                 WHERE doc_id = p_doc_id;
  DELETE FROM mcp_sched_supplies            WHERE source_doc_id = p_doc_id;

  -- Remove item shells this document created that are now empty and unused
  -- (per item, so one still-referenced item doesn't block cleaning the rest).
  IF v_items IS NOT NULL THEN
    DECLARE v_it uuid;
    BEGIN
      FOREACH v_it IN ARRAY v_items LOOP
        BEGIN
          DELETE FROM mcp_stocks_items i
          WHERE i.id = v_it
            AND NOT EXISTS (SELECT 1 FROM mcp_stocks_transactions t WHERE t.item_id = i.id)
            AND coalesce(i.current_qty, 0) = 0;
        EXCEPTION WHEN OTHERS THEN NULL;  -- keep any item still referenced elsewhere
        END;
      END LOOP;
    END;
  END IF;

  UPDATE mcp_logistics_documents
  SET status = 'cancelled',
      raw_extraction = COALESCE(raw_extraction, '{}'::jsonb)
                       || jsonb_build_object('cancelled_at', now(), 'cancelled_by', v_uid)
  WHERE id = p_doc_id;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END $function$;

create or replace function public.delete_logistics_document(p_doc_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_doc mcp_logistics_documents%rowtype;
  v_uid uuid := auth.uid();
  v_role user_role;
  v_items uuid[];
begin
  select * into v_doc from mcp_logistics_documents where id = p_doc_id;
  if v_doc.id is null then return jsonb_build_object('success', true, 'already', true); end if;
  if v_doc.plant_id <> my_plant_id() then return jsonb_build_object('success', false, 'error', 'Not your plant'); end if;

  select role into v_role from users where id = v_uid;
  if not (v_role in ('admin'::user_role, 'plant_head'::user_role)
          or (v_doc.created_by = v_uid and v_doc.created_at > now() - interval '24 hours')) then
    return jsonb_build_object('success', false, 'error', 'You can delete a document only within 24 hours of creating it, or as an admin / plant head.');
  end if;

  select array_agg(distinct item_id) into v_items from mcp_stocks_transactions where document_id = p_doc_id;

  delete from mcp_project_material_usage    where document_id = p_doc_id;
  delete from mcp_stocks_transactions       where document_id = p_doc_id;
  delete from mcp_rdc_receipts              where doc_id = p_doc_id;
  delete from mcp_logistics_grn_lines       where doc_id = p_doc_id;
  delete from mcp_logistics_grn_receptions  where doc_id = p_doc_id or document_id = p_doc_id;
  delete from mcp_logistics_jobwork_lines   where doc_id = p_doc_id;
  delete from mcp_rdc_lines                 where doc_id = p_doc_id;
  delete from mcp_sched_supplies            where source_doc_id = p_doc_id;

  if v_items is not null then
    declare v_it uuid;
    begin
      foreach v_it in array v_items loop
        begin
          delete from mcp_stocks_items i
          where i.id = v_it
            and not exists (select 1 from mcp_stocks_transactions t where t.item_id = i.id)
            and coalesce(i.current_qty, 0) = 0;
        exception when others then null;  -- keep any item still referenced elsewhere
        end;
      end loop;
    end;
  end if;

  delete from mcp_logistics_documents       where id = p_doc_id;

  return jsonb_build_object('success', true);
exception when others then return jsonb_build_object('success', false, 'error', sqlerrm);
end $function$;
grant execute on function public.delete_logistics_document(uuid) to authenticated;
grant execute on function public.cancel_logistics_document(uuid) to authenticated;
