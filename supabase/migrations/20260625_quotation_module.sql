-- Machining quotation / costing module.
-- A quotation = a part with an auto-computed material cost (bar dia x length x
-- density x rate) plus a list of process charges (CNC turning, grinding, ...).
-- grand_total = material_cost + sum(item prices).
CREATE TABLE IF NOT EXISTS public.mcp_quotations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id      uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  quote_no      text,
  customer_name text,
  product_name  text NOT NULL,
  material      text,
  mat_shape     text DEFAULT 'round',           -- round | flat | tube
  mat_dia       numeric,                          -- mm (OD for round/tube, width for flat)
  mat_width     numeric,                          -- mm (flat) / ID (tube)
  mat_length    numeric,                          -- mm
  mat_density   numeric DEFAULT 7.85,             -- g/cc
  mat_rate      numeric,                          -- Rs / kg
  mat_weight_g  numeric,                          -- computed grams
  mat_cost      numeric DEFAULT 0,                -- computed Rs
  qty           integer DEFAULT 1,
  notes         text,
  grand_total   numeric DEFAULT 0,
  status        text DEFAULT 'draft',             -- draft | sent | accepted | rejected
  created_by    uuid REFERENCES public.users(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.mcp_quotations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mcp_quotations_all ON public.mcp_quotations;
CREATE POLICY mcp_quotations_all ON public.mcp_quotations FOR ALL
  USING (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()))
  WITH CHECK (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()));
CREATE INDEX IF NOT EXISTS mcp_quotations_plant_idx ON public.mcp_quotations (plant_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.mcp_quotation_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id  uuid NOT NULL REFERENCES public.mcp_quotations(id) ON DELETE CASCADE,
  process       text,
  description   text,
  price         numeric DEFAULT 0,
  sort_order    integer DEFAULT 0
);
ALTER TABLE public.mcp_quotation_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mcp_quotation_items_all ON public.mcp_quotation_items;
CREATE POLICY mcp_quotation_items_all ON public.mcp_quotation_items FOR ALL
  USING (auth.uid() IS NOT NULL AND quotation_id IN (
    SELECT q.id FROM mcp_quotations q JOIN users u ON u.plant_id = q.plant_id WHERE u.id = auth.uid()))
  WITH CHECK (auth.uid() IS NOT NULL AND quotation_id IN (
    SELECT q.id FROM mcp_quotations q JOIN users u ON u.plant_id = q.plant_id WHERE u.id = auth.uid()));
CREATE INDEX IF NOT EXISTS mcp_quotation_items_qid_idx ON public.mcp_quotation_items (quotation_id, sort_order);
