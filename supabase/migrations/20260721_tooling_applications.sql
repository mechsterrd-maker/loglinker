-- Tool & Insert Planner — applications matrix. One row per (insert × part ×
-- operation), each with its OWN tool life and the part's monthly volume. An
-- insert's monthly requirement rolls up as SUM(monthly_parts / pcs_per_insert)
-- across all its applications — so a shared insert with a different life on each
-- part is planned correctly. When an item has no applications, the planner falls
-- back to the item-level single-driver fields. Plant-scoped + unit-isolated.

CREATE TABLE IF NOT EXISTS public.tooling_applications (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id       uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id        uuid REFERENCES public.units(id) ON DELETE SET NULL,
  item_id        uuid NOT NULL REFERENCES public.tooling_items(id) ON DELETE CASCADE,
  part_id        uuid REFERENCES public.mcp_pdc_parts(id) ON DELETE SET NULL,
  part_number    text,
  operation      text,
  pcs_per_insert numeric,                 -- tool life on THIS part / operation
  monthly_parts  numeric NOT NULL DEFAULT 0,
  seq            integer NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_tooling_app_item ON public.tooling_applications(item_id, seq);

DO $$
DECLARE t text := 'tooling_applications';
BEGIN
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
  EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t||'_sel', t);
  EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t||'_ins', t);
  EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t||'_upd', t);
  EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t||'_del', t);
  EXECUTE format('DROP POLICY IF EXISTS unit_iso ON public.%I', t);
  EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (plant_id = my_plant_id())', t||'_sel', t);
  EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (plant_id = my_plant_id())', t||'_ins', t);
  EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (plant_id = my_plant_id()) WITH CHECK (plant_id = my_plant_id())', t||'_upd', t);
  EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (plant_id = my_plant_id())', t||'_del', t);
  EXECUTE format('CREATE POLICY unit_iso ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING (public.unit_visible(unit_id)) WITH CHECK (public.unit_visible(unit_id))', t);
  EXECUTE format('DROP TRIGGER IF EXISTS trg_set_unit ON public.%I', t);
  EXECUTE format('CREATE TRIGGER trg_set_unit BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_unit_from_active()', t);
END $$;
