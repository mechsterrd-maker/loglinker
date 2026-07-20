-- PPAP Builder — reusable part-family library. A template captures a process
-- flow and/or a characteristics set once so the next similar part reuses them
-- (then Draft PFMEA regenerates the FMEA from the flow). Plant-wide (not tied to
-- one submission), unit-isolated like the rest of the PPAP tables.

CREATE TABLE IF NOT EXISTS public.ppap_templates (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id   uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id    uuid REFERENCES public.units(id) ON DELETE SET NULL,
  name       text NOT NULL,
  family     text,
  steps      jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{seq,operation,machine,control_method,notes}]
  chars      jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{balloon_no,description,nominal,tol_plus,tol_minus,uom,gd_t,classification}]
  created_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ppap_tpl_plant ON public.ppap_templates(plant_id, family);

DO $$
DECLARE t text := 'ppap_templates';
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
