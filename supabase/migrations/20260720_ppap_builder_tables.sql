-- PPAP Builder — child tables hung off an existing iatf_ppap_submissions row
-- (the packet "project"). Each is plant-scoped + unit-isolated exactly like the
-- rest of the app: PERMISSIVE plant policies + RESTRICTIVE unit_visible() policy +
-- set_unit_from_active() auto-stamp trigger (see 20260628_unit_isolation_3).

CREATE TABLE IF NOT EXISTS public.ppap_characteristics (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id       uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id        uuid REFERENCES public.units(id) ON DELETE SET NULL,
  ppap_id        uuid NOT NULL REFERENCES public.iatf_ppap_submissions(id) ON DELETE CASCADE,
  seq            integer NOT NULL DEFAULT 0,
  balloon_no     text, description text, nominal numeric, tol_plus numeric, tol_minus numeric,
  uom text, gd_t text,
  classification text DEFAULT 'none',        -- cc | sc | none
  source         text DEFAULT 'manual',      -- cadnexa | manual | scl | csv
  is_key         boolean NOT NULL DEFAULT false,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ppap_char_ppap ON public.ppap_characteristics(ppap_id, seq);

CREATE TABLE IF NOT EXISTS public.ppap_measurements (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id          uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id           uuid REFERENCES public.units(id) ON DELETE SET NULL,
  characteristic_id uuid NOT NULL REFERENCES public.ppap_characteristics(id) ON DELETE CASCADE,
  sample_no         integer NOT NULL DEFAULT 1,
  actual            numeric,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (characteristic_id, sample_no)
);
CREATE INDEX IF NOT EXISTS idx_ppap_meas_char ON public.ppap_measurements(characteristic_id, sample_no);

CREATE TABLE IF NOT EXISTS public.ppap_process_steps (
  id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id  uuid REFERENCES public.units(id) ON DELETE SET NULL,
  ppap_id  uuid NOT NULL REFERENCES public.iatf_ppap_submissions(id) ON DELETE CASCADE,
  seq integer NOT NULL DEFAULT 0, operation text, machine text, control_method text, notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ppap_step_ppap ON public.ppap_process_steps(ppap_id, seq);

CREATE TABLE IF NOT EXISTS public.ppap_elements (
  id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id  uuid REFERENCES public.units(id) ON DELETE SET NULL,
  ppap_id  uuid NOT NULL REFERENCES public.iatf_ppap_submissions(id) ON DELETE CASCADE,
  element_key text NOT NULL,
  status text NOT NULL DEFAULT 'pending', -- na | pending | in_progress | complete
  source_ref text, doc_url text, notes text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (ppap_id, element_key)
);

CREATE TABLE IF NOT EXISTS public.ppap_documents (
  id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id  uuid REFERENCES public.units(id) ON DELETE SET NULL,
  ppap_id  uuid NOT NULL REFERENCES public.iatf_ppap_submissions(id) ON DELETE CASCADE,
  kind text, title text, file_url text, file_size bigint, content_type text,
  uploaded_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  uploaded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ppap_doc_ppap ON public.ppap_documents(ppap_id);

-- RLS: plant scope + unit isolation + auto-stamp, for all five tables.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ppap_characteristics','ppap_measurements','ppap_process_steps','ppap_elements','ppap_documents']
  LOOP
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
  END LOOP;
END $$;
