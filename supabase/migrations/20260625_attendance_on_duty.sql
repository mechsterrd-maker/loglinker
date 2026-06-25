-- On-Duty (OD) attendance: staff working off-site (customer visit, field work)
-- who can't punch at the gate. Counts as a paid present-equivalent day.
ALTER TABLE public.mcp_attendance DROP CONSTRAINT IF EXISTS mcp_attendance_status_check;
ALTER TABLE public.mcp_attendance ADD CONSTRAINT mcp_attendance_status_check
  CHECK (status = ANY (ARRAY['present','absent','half_day','leave','week_off','holiday','wfh','on_duty']));

ALTER TABLE public.mcp_attendance DROP CONSTRAINT IF EXISTS mcp_attendance_mark_method_check;
ALTER TABLE public.mcp_attendance ADD CONSTRAINT mcp_attendance_mark_method_check
  CHECK (mark_method = ANY (ARRAY['supervisor','self_gps_qr','self_onduty']));

CREATE OR REPLACE VIEW public.v_attendance_today AS
SELECT plant_id, date,
       COUNT(*) FILTER (WHERE status = 'present')   AS present_count,
       COUNT(*) FILTER (WHERE status = 'absent')    AS absent_count,
       COUNT(*) FILTER (WHERE status = 'half_day')  AS half_day_count,
       COUNT(*) FILTER (WHERE status = 'leave')     AS leave_count,
       COUNT(*) FILTER (WHERE status = 'week_off')  AS week_off_count,
       COUNT(*) FILTER (WHERE status = 'holiday')   AS holiday_count,
       COUNT(*) FILTER (WHERE status = 'wfh')       AS wfh_count,
       COUNT(*) FILTER (WHERE status = 'on_duty')   AS on_duty_count
FROM public.mcp_attendance
GROUP BY plant_id, date;

-- Employee self-marks On Duty from their phone — no gate QR / geofence needed
-- (they're away). GPS + an optional reason are captured for the record.
CREATE OR REPLACE FUNCTION public.attendance_self_mark_onduty(p_plant_id uuid, p_lat numeric, p_lng numeric, p_note text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_user_id uuid := auth.uid(); v_existing mcp_attendance;
BEGIN
  IF v_user_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','Not authenticated'); END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id=v_user_id AND plant_id=p_plant_id) THEN
    RETURN jsonb_build_object('success',false,'error','You are not a member of this plant'); END IF;
  SELECT * INTO v_existing FROM mcp_attendance WHERE plant_id=p_plant_id AND user_id=v_user_id AND date=current_date;
  IF FOUND THEN
    UPDATE mcp_attendance SET status='on_duty', mark_method='self_onduty',
      captured_in_lat=COALESCE(p_lat, captured_in_lat), captured_in_lng=COALESCE(p_lng, captured_in_lng),
      notes=COALESCE(NULLIF(p_note,''), notes), marked_by=v_user_id
      WHERE id=v_existing.id;
  ELSE
    INSERT INTO mcp_attendance (plant_id,user_id,date,status,captured_in_lat,captured_in_lng,notes,mark_method,marked_by)
      VALUES (p_plant_id,v_user_id,current_date,'on_duty',p_lat,p_lng,NULLIF(p_note,''),'self_onduty',v_user_id);
  END IF;
  RETURN jsonb_build_object('success',true,'message','Marked On Duty for today');
END $function$;
