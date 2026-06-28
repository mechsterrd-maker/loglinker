-- Per-unit data isolation — RLS LOCK + AUTO-STAMP (this is where behavior changes).
-- A RESTRICTIVE unit_visible() policy is AND'd on top of each table's existing
-- plant-scoped policies, so unit staff physically cannot read/write other units'
-- rows; owners/MD/all-unit managers are unaffected; NULL unit_id = shared. A
-- BEFORE INSERT trigger stamps the user's active unit so writes are tagged
-- without editing every frontend create.

-- Auto-stamp the active unit on insert (auth.uid() is the real caller here).
CREATE OR REPLACE FUNCTION public.set_unit_from_active()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if NEW.unit_id is null then
    NEW.unit_id := (select active_unit_id from public.users where id = auth.uid());
  end if;
  return NEW;
end;
$function$;

-- Apply to every base data table with both plant_id and unit_id. Add a permissive
-- plant baseline first to any table with no policy, so enabling RLS never denies-all.
DO $$
DECLARE r record; exclude text[] := ARRAY['user_unit_access','shifts','departments'];
BEGIN
  FOR r IN
    SELECT c.relname AS t FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind='r'
      AND EXISTS (SELECT 1 FROM information_schema.columns col WHERE col.table_schema='public' AND col.table_name=c.relname AND col.column_name='unit_id')
      AND EXISTS (SELECT 1 FROM information_schema.columns col WHERE col.table_schema='public' AND col.table_name=c.relname AND col.column_name='plant_id')
      AND c.relname <> ALL(exclude)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname='public' AND p.tablename=r.t) THEN
      EXECUTE format('CREATE POLICY plant_base ON public.%I FOR ALL TO authenticated USING (plant_id = my_plant_id()) WITH CHECK (plant_id = my_plant_id())', r.t);
    END IF;
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.t);
    EXECUTE format('DROP POLICY IF EXISTS unit_iso ON public.%I', r.t);
    EXECUTE format('CREATE POLICY unit_iso ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING (public.unit_visible(unit_id)) WITH CHECK (public.unit_visible(unit_id))', r.t);
    EXECUTE format('DROP TRIGGER IF EXISTS trg_set_unit ON public.%I', r.t);
    EXECUTE format('CREATE TRIGGER trg_set_unit BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_unit_from_active()', r.t);
  END LOOP;
END $$;

-- Chat: BILLS-OCR groups are common across units (per the model) -> unit_id NULL.
UPDATE public.chat_groups SET unit_id = NULL
WHERE coalesce(ai_logistics_enabled,false) = true OR name = 'BILLS-OCR';

-- OCR bills: the extract-document edge function runs as service_role (auth.uid()
-- null), so copy the unit from the source extraction_queue row (set by the
-- uploader's client). Fires before the generic trg_set_unit ('d' < 's').
CREATE OR REPLACE FUNCTION public.doc_unit_from_queue()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if NEW.unit_id is null and NEW.source_message_id is not null then
    NEW.unit_id := (select unit_id from public.mcp_logistics_extraction_queue
                    where message_id = NEW.source_message_id and unit_id is not null
                    order by created_at desc limit 1);
  end if;
  return NEW;
end;
$function$;
DROP TRIGGER IF EXISTS trg_doc_unit_from_queue ON public.mcp_logistics_documents;
CREATE TRIGGER trg_doc_unit_from_queue
  BEFORE INSERT ON public.mcp_logistics_documents
  FOR EACH ROW EXECUTE FUNCTION public.doc_unit_from_queue();
