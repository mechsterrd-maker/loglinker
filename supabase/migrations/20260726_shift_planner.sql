-- Shift planner: reusable shift templates + per-employee per-day assignments (weekly roster).
CREATE TABLE IF NOT EXISTS public.mcp_shift_templates (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id   uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  name       text NOT NULL,
  start_time time NOT NULL,
  end_time   time NOT NULL,
  color      text,
  sort       int  NOT NULL DEFAULT 0,
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.mcp_shift_templates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mcp_shift_templates_all ON public.mcp_shift_templates;
CREATE POLICY mcp_shift_templates_all ON public.mcp_shift_templates FOR ALL
  USING (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()))
  WITH CHECK (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()));
CREATE INDEX IF NOT EXISTS mcp_shift_templates_plant_idx ON public.mcp_shift_templates (plant_id, active);

CREATE TABLE IF NOT EXISTS public.mcp_shift_assignments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id    uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  date        date NOT NULL,
  template_id uuid REFERENCES public.mcp_shift_templates(id) ON DELETE SET NULL,
  is_off      boolean NOT NULL DEFAULT false,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plant_id, user_id, date)
);
ALTER TABLE public.mcp_shift_assignments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mcp_shift_assignments_all ON public.mcp_shift_assignments;
CREATE POLICY mcp_shift_assignments_all ON public.mcp_shift_assignments FOR ALL
  USING (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()))
  WITH CHECK (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()));
CREATE INDEX IF NOT EXISTS mcp_shift_assignments_plant_date_idx ON public.mcp_shift_assignments (plant_id, date);
