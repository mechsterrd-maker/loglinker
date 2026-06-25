-- On-Duty overtime: capture hours worked on an OD day so payroll can pay OT
-- for hours beyond the shift (short-time is never deducted for OD).
DROP FUNCTION IF EXISTS public.attendance_self_mark_onduty(uuid, numeric, numeric, text);
CREATE OR REPLACE FUNCTION public.attendance_self_mark_onduty(p_plant_id uuid, p_lat numeric, p_lng numeric, p_note text, p_hours numeric)
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
      notes=COALESCE(NULLIF(p_note,''), notes), hours_worked=COALESCE(p_hours, hours_worked), marked_by=v_user_id
      WHERE id=v_existing.id;
  ELSE
    INSERT INTO mcp_attendance (plant_id,user_id,date,status,captured_in_lat,captured_in_lng,notes,hours_worked,mark_method,marked_by)
      VALUES (p_plant_id,v_user_id,current_date,'on_duty',p_lat,p_lng,NULLIF(p_note,''),p_hours,'self_onduty',v_user_id);
  END IF;
  RETURN jsonb_build_object('success',true,'message','Marked On Duty for today');
END $function$;
