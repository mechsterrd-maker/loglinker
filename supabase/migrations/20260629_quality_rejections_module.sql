-- Daily Rejection & Analytics module: daily rejection log feeding Pareto / PPM /
-- COPQ / Rework dashboards (mirrors the company's Excel). Reuses existing parts,
-- rejection types, inspectors. Two new tables + a cost/piece column on parts.

-- Per-part cost so COPQ (Cost of Poor Quality) can value scrap & rework.
ALTER TABLE public.mcp_pdc_parts ADD COLUMN IF NOT EXISTS cost_per_piece numeric;

-- Daily rejection entries (inhouse / supplier / customer).
CREATE TABLE IF NOT EXISTS public.mcp_quality_rejections (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id        uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id         uuid REFERENCES public.units(id) ON DELETE SET NULL,
  rej_date        date NOT NULL DEFAULT current_date,
  category        text NOT NULL DEFAULT 'inhouse',   -- inhouse | supplier | customer
  part_id         uuid REFERENCES public.mcp_pdc_parts(id) ON DELETE SET NULL,
  part_name       text,
  model           text,
  reason          text NOT NULL,
  found_stage     text,
  total_qty       numeric NOT NULL DEFAULT 0,
  rework_qty      numeric NOT NULL DEFAULT 0,
  suspected_qty   numeric NOT NULL DEFAULT 0,
  scrap_qty       numeric NOT NULL DEFAULT 0,
  supplier_name   text,
  supplier_debit  boolean NOT NULL DEFAULT false,
  issue_details   text,
  inspector_name  text,
  inspector_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  cavity          text,
  cost_per_piece  numeric,
  remarks         text,
  created_by      uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_qr_plant_date ON public.mcp_quality_rejections(plant_id, rej_date DESC);
CREATE INDEX IF NOT EXISTS idx_qr_unit ON public.mcp_quality_rejections(unit_id);

-- Monthly received/produced qty per category — denominator for PPM.
CREATE TABLE IF NOT EXISTS public.mcp_quality_ppm_base (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id     uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id      uuid REFERENCES public.units(id) ON DELETE SET NULL,
  month        date NOT NULL,                        -- first of month
  category     text NOT NULL DEFAULT 'inhouse',
  received_qty numeric NOT NULL DEFAULT 0,
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plant_id, unit_id, month, category)
);

ALTER TABLE public.mcp_quality_rejections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mcp_quality_ppm_base   ENABLE ROW LEVEL SECURITY;
