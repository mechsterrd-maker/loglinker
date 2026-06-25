-- Payroll module: per-employee pay config + plant holiday calendar.
--
-- Overtime model (computed client-side from mcp_attendance.hours_worked):
--   hourly_rate = monthly_salary / payroll_days_divisor / shift_hours
--   normal day:  OT hours = max(0, hours_worked - shift_hours)
--   Sunday / govt holiday: ALL hours_worked are OT
--   OT pay = OT hours * hourly_rate * ot_multiplier
--   gross  = monthly_salary + OT pay

-- Plant chooses the salary→day divisor (26 excludes weekly offs, 30 = calendar).
ALTER TABLE public.plants
  ADD COLUMN IF NOT EXISTS payroll_days_divisor int DEFAULT 26;

-- Per-employee pay configuration.
CREATE TABLE IF NOT EXISTS public.mcp_payroll_config (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id       uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  monthly_salary numeric(12,2) DEFAULT 0,
  shift_hours    numeric(4,2)  DEFAULT 8,
  ot_multiplier  numeric(4,2)  DEFAULT 1.5,
  updated_at     timestamptz   NOT NULL DEFAULT now(),
  UNIQUE (plant_id, user_id)
);
ALTER TABLE public.mcp_payroll_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mcp_payroll_config_all ON public.mcp_payroll_config;
CREATE POLICY mcp_payroll_config_all ON public.mcp_payroll_config FOR ALL
  USING (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()))
  WITH CHECK (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()));

-- Plant holiday calendar — any date here is treated as overtime when worked.
CREATE TABLE IF NOT EXISTS public.mcp_plant_holidays (
  id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  date     date NOT NULL,
  name     text,
  UNIQUE (plant_id, date)
);
ALTER TABLE public.mcp_plant_holidays ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mcp_plant_holidays_all ON public.mcp_plant_holidays;
CREATE POLICY mcp_plant_holidays_all ON public.mcp_plant_holidays FOR ALL
  USING (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()))
  WITH CHECK (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()));
CREATE INDEX IF NOT EXISTS mcp_plant_holidays_plant_idx ON public.mcp_plant_holidays (plant_id, date);
