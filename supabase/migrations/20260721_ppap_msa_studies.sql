-- PPAP Builder — Element 8: Measurement System Analysis (Gauge R&R).
-- One row per study; the raw operator×part×trial readings live in `readings`
-- (jsonb: [{op,part,trial,v}]) and %GRR / %P-T / ndc are computed client-side by
-- the AIAG Average-and-Range method. Plant-scoped + unit-isolated like the rest
-- of the PPAP tables (see 20260720_ppap_builder_tables.sql).

CREATE TABLE IF NOT EXISTS public.ppap_msa_studies (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id          uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id           uuid REFERENCES public.units(id) ON DELETE SET NULL,
  ppap_id           uuid NOT NULL REFERENCES public.iatf_ppap_submissions(id) ON DELETE CASCADE,
  characteristic_id uuid REFERENCES public.ppap_characteristics(id) ON DELETE SET NULL,
  gauge_name        text,
  gauge_id_no       text,
  n_operators       smallint NOT NULL DEFAULT 3,
  n_parts           smallint NOT NULL DEFAULT 10,
  n_trials          smallint NOT NULL DEFAULT 3,
  tolerance         numeric,                       -- for %P/T (study vs tolerance)
  readings          jsonb NOT NULL DEFAULT '[]'::jsonb,  -- [{op,part,trial,v}]
  notes             text,
  created_by        uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ppap_msa_ppap ON public.ppap_msa_studies(ppap_id);

DO $$
DECLARE t text := 'ppap_msa_studies';
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
