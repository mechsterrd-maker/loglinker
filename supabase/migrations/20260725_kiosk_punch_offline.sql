-- Offline-capable kiosk punch: accept an optional real punch time (p_at) so a
-- punch made while the gate was offline records the time it ACTUALLY happened,
-- not the moment it syncs. p_at null → behaves exactly as before (uses now()).
-- The client queues punches locally when offline and replays them with p_at.
DROP FUNCTION IF EXISTS public.attendance_kiosk_punch(uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.attendance_kiosk_punch(
  p_plant_id uuid, p_user_id uuid, p_dir text DEFAULT NULL, p_at timestamptz DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_role   text;
  v_name   text;
  v_existing mcp_attendance;
  v_dir    text := p_dir;
  v_hours  numeric;
  v_ts     timestamptz := COALESCE(p_at, now());
  v_now    time := (v_ts AT TIME ZONE 'Asia/Kolkata')::time;
  v_date   date := (v_ts AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  IF v_caller IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Not authenticated'); END IF;
  SELECT role INTO v_role FROM users WHERE id = v_caller AND plant_id = p_plant_id;
  IF v_role IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Kiosk device is not a member of this plant'); END IF;
  IF v_role NOT IN ('admin','plant_head','manager','supervisor') THEN
    RETURN jsonb_build_object('success', false, 'error', 'This device is not allowed to run the attendance kiosk');
  END IF;
  SELECT full_name INTO v_name FROM users WHERE id = p_user_id AND plant_id = p_plant_id;
  IF v_name IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Matched worker is not in this plant'); END IF;

  SELECT * INTO v_existing FROM mcp_attendance
   WHERE plant_id = p_plant_id AND user_id = p_user_id AND date = v_date;

  IF v_dir IS NULL THEN
    IF v_existing.id IS NULL OR v_existing.in_time IS NULL THEN v_dir := 'in';
    ELSIF v_existing.out_time IS NULL THEN v_dir := 'out';
    ELSE RETURN jsonb_build_object('success', false, 'name', v_name,
      'error', v_name || ' already marked IN & OUT'); END IF;
  END IF;

  IF v_dir = 'in' THEN
    IF v_existing.id IS NOT NULL AND v_existing.in_time IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'name', v_name,
        'error', v_name || ' already IN at ' || to_char(v_date + v_existing.in_time, 'HH24:MI'));
    END IF;
    IF v_existing.id IS NOT NULL THEN
      UPDATE mcp_attendance SET in_time = v_now,
        status = CASE WHEN status = 'absent' THEN 'present' ELSE status END,
        mark_method = 'face_kiosk', marked_by = v_caller WHERE id = v_existing.id;
    ELSE
      INSERT INTO mcp_attendance (plant_id, user_id, date, status, in_time, mark_method, marked_by)
        VALUES (p_plant_id, p_user_id, v_date, 'present', v_now, 'face_kiosk', v_caller);
    END IF;
    RETURN jsonb_build_object('success', true, 'name', v_name, 'dir', 'in',
      'message', v_name || ' — IN at ' || to_char(v_date + v_now, 'HH24:MI'));
  ELSE
    IF v_existing.id IS NULL OR v_existing.in_time IS NULL THEN
      RETURN jsonb_build_object('success', false, 'name', v_name, 'error', 'No IN punch for ' || v_name);
    END IF;
    IF v_existing.out_time IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'name', v_name,
        'error', v_name || ' already OUT at ' || to_char(v_date + v_existing.out_time, 'HH24:MI'));
    END IF;
    v_hours := EXTRACT(EPOCH FROM (v_now - v_existing.in_time)) / 3600.0;
    UPDATE mcp_attendance SET out_time = v_now, hours_worked = round(v_hours::numeric, 2) WHERE id = v_existing.id;
    RETURN jsonb_build_object('success', true, 'name', v_name, 'dir', 'out',
      'message', v_name || ' — OUT at ' || to_char(v_date + v_now, 'HH24:MI') || ' · ' || to_char(round(v_hours::numeric,1),'FM999.0') || ' hrs');
  END IF;
END $function$;
