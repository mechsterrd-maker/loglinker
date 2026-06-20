-- Attendance — one row per (plant, employee, date). Status covers the
-- common Indian SME pattern (P/A/HD/L/WO/H/WFH). Optional in/out/hours.
CREATE TABLE IF NOT EXISTS public.mcp_attendance (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id    uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id     uuid REFERENCES public.units(id) ON DELETE SET NULL,
  user_id     uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  date        date NOT NULL,
  status      text NOT NULL CHECK (status IN ('present','absent','half_day','leave','week_off','holiday','wfh')),
  in_time     time,
  out_time    time,
  hours_worked numeric(5,2),
  notes       text,
  marked_by   uuid REFERENCES public.users(id),
  marked_at   timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plant_id, user_id, date)
);
CREATE INDEX IF NOT EXISTS mcp_attendance_plant_date_idx ON public.mcp_attendance (plant_id, date DESC);
CREATE INDEX IF NOT EXISTS mcp_attendance_user_date_idx  ON public.mcp_attendance (user_id, date DESC);

ALTER TABLE public.mcp_attendance ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mcp_attendance_select ON public.mcp_attendance;
CREATE POLICY mcp_attendance_select ON public.mcp_attendance FOR SELECT
  USING (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()));
DROP POLICY IF EXISTS mcp_attendance_modify ON public.mcp_attendance;
CREATE POLICY mcp_attendance_modify ON public.mcp_attendance FOR ALL
  USING (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()))
  WITH CHECK (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()));

CREATE OR REPLACE VIEW public.v_attendance_today AS
SELECT plant_id, date,
       COUNT(*) FILTER (WHERE status = 'present')   AS present_count,
       COUNT(*) FILTER (WHERE status = 'absent')    AS absent_count,
       COUNT(*) FILTER (WHERE status = 'half_day')  AS half_day_count,
       COUNT(*) FILTER (WHERE status = 'leave')     AS leave_count,
       COUNT(*) FILTER (WHERE status = 'week_off')  AS week_off_count,
       COUNT(*) FILTER (WHERE status = 'holiday')   AS holiday_count,
       COUNT(*) FILTER (WHERE status = 'wfh')       AS wfh_count
FROM public.mcp_attendance
GROUP BY plant_id, date;

CREATE OR REPLACE FUNCTION public.attendance_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END
$$;
DROP TRIGGER IF EXISTS mcp_attendance_updated_at ON public.mcp_attendance;
CREATE TRIGGER mcp_attendance_updated_at
  BEFORE UPDATE ON public.mcp_attendance
  FOR EACH ROW EXECUTE FUNCTION public.attendance_set_updated_at();

-- Plant-level tab gating. NULL = all tabs visible.
ALTER TABLE public.plants
  ADD COLUMN IF NOT EXISTS enabled_tabs text[];
