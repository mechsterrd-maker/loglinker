-- Tool & Insert Planner — a simple, self-contained consumable-tooling planner for
-- machining plants. Each item carries its tool life (edges × parts/edge) and the
-- monthly production it serves; the app computes monthly insert need, reorder qty
-- and months of cover. Usage/receipts are logged to keep stock live and to show
-- actual consumption. Plant-scoped + unit-isolated like the rest of the app.

CREATE TABLE IF NOT EXISTS public.tooling_items (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id         uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id          uuid REFERENCES public.units(id) ON DELETE SET NULL,
  name             text NOT NULL,
  iso_code         text,                              -- grade / ISO designation e.g. CNMG120408
  category         text NOT NULL DEFAULT 'insert',    -- insert | drill | endmill | tap | tool | other
  machine          text,
  operation        text,
  edges_per_insert numeric NOT NULL DEFAULT 1,        -- indexable cutting corners
  parts_per_edge   numeric,                           -- tool life: components per edge
  monthly_parts    numeric NOT NULL DEFAULT 0,        -- production volume/month this tool serves
  current_stock    numeric NOT NULL DEFAULT 0,
  safety_stock     numeric NOT NULL DEFAULT 0,
  unit_cost        numeric,
  uom              text NOT NULL DEFAULT 'nos',
  active           boolean NOT NULL DEFAULT true,
  notes            text,
  created_by       uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_tooling_items_plant ON public.tooling_items(plant_id, category);

CREATE TABLE IF NOT EXISTS public.tooling_txns (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id      uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id       uuid REFERENCES public.units(id) ON DELETE SET NULL,
  item_id       uuid NOT NULL REFERENCES public.tooling_items(id) ON DELETE CASCADE,
  txn_type      text NOT NULL DEFAULT 'consumption',  -- receipt | consumption | adjustment
  qty           numeric NOT NULL,                     -- inserts (stored positive)
  parts_made    numeric,                              -- optional: components produced (consumption)
  reference     text,
  performed_by  uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_tooling_txns_item ON public.tooling_txns(item_id, created_at DESC);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['tooling_items','tooling_txns']
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

-- RBAC: grant the tooling module to every built-in role on existing plants
-- (shop-floor + management all use it). New plants inherit via their seed.
INSERT INTO public.role_permissions (role_id, module_key, action)
SELECT pr.id, 'tooling', '*'
FROM public.plant_roles pr
WHERE pr.is_builtin
ON CONFLICT DO NOTHING;
