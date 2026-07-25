-- Night-shift + forgotten-punch-out aware kiosk punch.
-- OUT attaches to the OPEN shift (in set, out null) from today OR yesterday, so a
-- worker who punches IN tonight and OUT tomorrow morning is counted PRESENT on the
-- IN day, with hours computed across midnight. If the open shift is older than
-- ~18h it's treated as a forgotten punch-out: this punch starts a fresh IN and the
-- stale record is left open (still counts present; admin can fix the hours).
DROP FUNCTION IF EXISTS public.attendance_kiosk_punch(uuid, uuid, text, timestamptz);
DROP FUNCTION IF EXISTS public.attendance_kiosk_punch(uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.attendance_kiosk_punch(
  p_plant_id uuid, p_user_id uuid, p_dir text DEFAULT NULL, p_at timestamptz DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_role   text; v_name text;
  v_today  mcp_attendance;
  v_open   mcp_attendance;
  v_dir    text := p_dir;
  v_hours  numeric; v_gap numeric;
  v_in_ts  timestamptz; v_out_ts timestamptz;
  v_ts     timestamptz := COALESCE(p_at, now());
  v_now    time := (v_ts AT TIME ZONE 'Asia/Kolkata')::time;
  v_date   date := (v_ts AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  IF v_caller IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Not authenticated'); END IF;
  SELECT role INTO v_role FROM users WHERE id = v_caller AND plant_id = p_plant_id;
  IF v_role IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Kiosk device is not a member of this plant'); END IF;
  IF v_role NOT IN ('admin','plant_head','manager','supervisor') THEN
    RETURN jsonb_build_object('success', false, 'error', 'This device is not allowed to run the attendance kiosk'); END IF;
  SELECT full_name INTO v_name FROM users WHERE id = p_user_id AND plant_id = p_plant_id;
  IF v_name IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Matched worker is not in this plant'); END IF;

  SELECT * INTO v_today FROM mcp_attendance WHERE plant_id = p_plant_id AND user_id = p_user_id AND date = v_date;
  SELECT * INTO v_open FROM mcp_attendance
    WHERE plant_id = p_plant_id AND user_id = p_user_id AND in_time IS NOT NULL AND out_time IS NULL AND date >= v_date - 1
    ORDER BY date DESC, in_time DESC LIMIT 1;

  IF v_open.id IS NOT NULL THEN
    v_gap := EXTRACT(EPOCH FROM (v_ts - ((v_open.date + v_open.in_time) AT TIME ZONE 'Asia/Kolkata'))) / 3600.0;
  END IF;

  IF v_dir IS NULL THEN
    IF v_open.id IS NOT NULL AND v_gap IS NOT NULL AND v_gap <= 18 AND v_gap > 0.02 THEN v_dir := 'out';
    ELSE v_dir := 'in'; END IF;
  END IF;

  IF v_dir = 'in' THEN
    IF v_today.id IS NOT NULL AND v_today.in_time IS NOT NULL AND v_today.out_time IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'name', v_name, 'error', v_name || ' already marked IN & OUT today'); END IF;
    IF v_today.id IS NOT NULL AND v_today.in_time IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'name', v_name, 'error', v_name || ' already IN at ' || to_char(v_date + v_today.in_time, 'HH24:MI')); END IF;
    IF v_today.id IS NOT NULL THEN
      UPDATE mcp_attendance SET in_time = v_now,
        status = CASE WHEN status = 'absent' THEN 'present' ELSE status END,
        mark_method = 'face_kiosk', marked_by = v_caller WHERE id = v_today.id;
    ELSE
      INSERT INTO mcp_attendance (plant_id, user_id, date, status, in_time, mark_method, marked_by)
        VALUES (p_plant_id, p_user_id, v_date, 'present', v_now, 'face_kiosk', v_caller);
    END IF;
    RETURN jsonb_build_object('success', true, 'name', v_name, 'dir', 'in',
      'message', v_name || ' — IN at ' || to_char(v_date + v_now, 'HH24:MI'));
  ELSE
    IF v_open.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'name', v_name, 'error', 'No open IN punch for ' || v_name); END IF;
    v_in_ts := v_open.date + v_open.in_time;
    v_out_ts := v_date + v_now;
    IF v_out_ts <= v_in_ts THEN v_out_ts := v_out_ts + interval '1 day'; END IF;
    v_hours := EXTRACT(EPOCH FROM (v_out_ts - v_in_ts)) / 3600.0;
    UPDATE mcp_attendance SET out_time = v_now, hours_worked = round(v_hours::numeric, 2) WHERE id = v_open.id;
    RETURN jsonb_build_object('success', true, 'name', v_name, 'dir', 'out',
      'message', v_name || ' — OUT at ' || to_char(v_date + v_now, 'HH24:MI')
        || CASE WHEN v_open.date <> v_date THEN ' (in ' || to_char(v_open.date, 'DD Mon') || ')' ELSE '' END
        || ' · ' || to_char(round(v_hours::numeric,1),'FM999.0') || ' hrs');
  END IF;
END $function$;
