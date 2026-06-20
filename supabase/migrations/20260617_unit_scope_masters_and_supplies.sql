-- Unit-scoping for Krishnas Fittings (multi-business-unit plant):
--   Customers stay plant-wide (one Marvel for all units).
--   Parts / stock / schedules / supplies / sales docs / OCR queue gain
--   a unit_id so each unit has its own data even when sharing customers.
-- Nullable for backward compat — old rows are treated as plant-wide / shared.

ALTER TABLE public.mcp_pdc_parts                 ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id) ON DELETE SET NULL;
ALTER TABLE public.mcp_stocks_items              ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id) ON DELETE SET NULL;
ALTER TABLE public.mcp_sched_schedules           ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id) ON DELETE SET NULL;
ALTER TABLE public.mcp_sched_lines               ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id) ON DELETE SET NULL;
ALTER TABLE public.mcp_sched_supplies            ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id) ON DELETE SET NULL;
ALTER TABLE public.mcp_logistics_documents       ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id) ON DELETE SET NULL;
ALTER TABLE public.mcp_logistics_extraction_queue ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS mcp_pdc_parts_unit_idx               ON public.mcp_pdc_parts (plant_id, unit_id);
CREATE INDEX IF NOT EXISTS mcp_stocks_items_unit_idx            ON public.mcp_stocks_items (plant_id, unit_id);
CREATE INDEX IF NOT EXISTS mcp_sched_schedules_unit_idx         ON public.mcp_sched_schedules (plant_id, unit_id);
CREATE INDEX IF NOT EXISTS mcp_sched_lines_unit_idx             ON public.mcp_sched_lines (plant_id, unit_id);
CREATE INDEX IF NOT EXISTS mcp_sched_supplies_unit_idx          ON public.mcp_sched_supplies (plant_id, unit_id);
CREATE INDEX IF NOT EXISTS mcp_logistics_documents_unit_idx     ON public.mcp_logistics_documents (plant_id, unit_id);
CREATE INDEX IF NOT EXISTS mcp_logistics_extraction_queue_unit_idx ON public.mcp_logistics_extraction_queue (plant_id, unit_id);
