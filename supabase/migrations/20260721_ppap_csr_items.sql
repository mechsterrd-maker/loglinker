-- PPAP Builder — Element 17: Customer-Specific Requirements (CSR) checker.
-- One row per requirement on a submission. Auto-verifiable rule types
-- (min_cpk, min_ppap_level, max_grr, require_element) are evaluated client-side
-- against the live packet; 'manual' rules carry a `met` flag the user ticks.
-- Plant-scoped + unit-isolated like the other PPAP tables.

CREATE TABLE IF NOT EXISTS public.ppap_csr_items (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id    uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id     uuid REFERENCES public.units(id) ON DELETE SET NULL,
  ppap_id     uuid NOT NULL REFERENCES public.iatf_ppap_submissions(id) ON DELETE CASCADE,
  requirement text NOT NULL,
  rule_type   text NOT NULL DEFAULT 'manual',   -- min_cpk | min_ppap_level | max_grr | require_element | manual
  threshold   numeric,
  element_key text,
  met         boolean NOT NULL DEFAULT false,    -- for manual rules
  seq         integer NOT NULL DEFAULT 0,
  created_by  uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ppap_csr_ppap ON public.ppap_csr_items(ppap_id, seq);

DO $$
DECLARE t text := 'ppap_csr_items';
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
