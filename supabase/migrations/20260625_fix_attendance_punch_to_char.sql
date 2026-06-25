-- Fix self-attendance punch RPCs.
--
-- Bug: to_char(current_time, 'HH24:MI') / to_char(in_time, …) — Postgres has no
-- to_char(time/timetz, text) overload, so every punch failed with
-- "function to_char(time with time zone, unknown) does not exist".
--
-- Fix: format via (current_date + <time>)::timestamp, and store/display the
-- punch time in India time (Asia/Kolkata) instead of UTC so the gate clock is
-- correct. Date bucketing stays on current_date to match the client query.

CREATE OR REPLACE FUNCTION public.attendance_self_mark_in(p_plant_id uuid, p_qr text, p_lat numeric, p_lng numeric)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_plant     plants;
  v_user_id   uuid := auth.uid();
  v_distance  numeric;
  v_existing  mcp_attendance;
  v_now       time := (now() AT TIME ZONE 'Asia/Kolkata')::time;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;
  SELECT * INTO v_plant FROM plants WHERE id = p_plant_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Plant not found');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = v_user_id AND plant_id = p_plant_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'You are not a member of this plant');
  END IF;
  IF v_plant.attendance_mode <> 'self_gps_qr' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Self-attendance is not enabled for this plant');
  END IF;
  IF v_plant.attendance_qr_secret IS NULL OR v_plant.attendance_qr_secret <> p_qr THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wrong QR — please scan the QR posted at the factory gate');
  END IF;
  IF v_plant.geofence_lat IS NULL OR v_plant.geofence_lng IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Geofence not configured — ask your admin');
  END IF;
  IF p_lat IS NULL OR p_lng IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Could not read location — allow GPS permission and retry');
  END IF;

  v_distance := haversine_m(v_plant.geofence_lat, v_plant.geofence_lng, p_lat, p_lng);
  IF v_distance > v_plant.geofence_radius_m THEN
    RETURN jsonb_build_object('success', false,
      'error', format('You appear to be %s m from the factory — must be within %s m', round(v_distance), v_plant.geofence_radius_m),
      'distance_m', round(v_distance, 1), 'radius_m', v_plant.geofence_radius_m);
  END IF;

  SELECT * INTO v_existing FROM mcp_attendance
   WHERE plant_id = p_plant_id AND user_id = v_user_id AND date = current_date;

  IF FOUND THEN
    IF v_existing.in_time IS NOT NULL THEN
      RETURN jsonb_build_object('success', false,
        'error', 'Already marked IN today at ' || to_char(current_date + v_existing.in_time, 'HH24:MI'));
    END IF;
    UPDATE mcp_attendance
      SET in_time = v_now,
          status = CASE WHEN status = 'absent' THEN 'present' ELSE status END,
          captured_in_lat = p_lat, captured_in_lng = p_lng,
          captured_in_distance_m = round(v_distance, 1),
          mark_method = 'self_gps_qr', marked_by = v_user_id
      WHERE id = v_existing.id;
  ELSE
    INSERT INTO mcp_attendance (plant_id, user_id, date, status, in_time,
                                captured_in_lat, captured_in_lng, captured_in_distance_m,
                                mark_method, marked_by)
      VALUES (p_plant_id, v_user_id, current_date, 'present', v_now,
              p_lat, p_lng, round(v_distance, 1), 'self_gps_qr', v_user_id);
  END IF;

  RETURN jsonb_build_object('success', true,
    'message', 'Marked IN at ' || to_char(current_date + v_now, 'HH24:MI'),
    'distance_m', round(v_distance, 1));
END $function$;

CREATE OR REPLACE FUNCTION public.attendance_self_mark_out(p_plant_id uuid, p_qr text, p_lat numeric, p_lng numeric)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_plant     plants;
  v_user_id   uuid := auth.uid();
  v_distance  numeric;
  v_existing  mcp_attendance;
  v_hours     numeric;
  v_now       time := (now() AT TIME ZONE 'Asia/Kolkata')::time;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;
  SELECT * INTO v_plant FROM plants WHERE id = p_plant_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Plant not found'); END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = v_user_id AND plant_id = p_plant_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'You are not a member of this plant');
  END IF;
  IF v_plant.attendance_mode <> 'self_gps_qr' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Self-attendance is not enabled for this plant');
  END IF;
  IF v_plant.attendance_qr_secret IS NULL OR v_plant.attendance_qr_secret <> p_qr THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wrong QR — please scan the QR posted at the factory gate');
  END IF;
  IF v_plant.geofence_lat IS NULL OR v_plant.geofence_lng IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Geofence not configured');
  END IF;
  IF p_lat IS NULL OR p_lng IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Could not read location');
  END IF;

  v_distance := haversine_m(v_plant.geofence_lat, v_plant.geofence_lng, p_lat, p_lng);
  IF v_distance > v_plant.geofence_radius_m THEN
    RETURN jsonb_build_object('success', false,
      'error', format('You appear to be %s m from the factory', round(v_distance)),
      'distance_m', round(v_distance, 1));
  END IF;

  SELECT * INTO v_existing FROM mcp_attendance
   WHERE plant_id = p_plant_id AND user_id = v_user_id AND date = current_date;
  IF NOT FOUND OR v_existing.in_time IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No IN punch found for today');
  END IF;
  IF v_existing.out_time IS NOT NULL THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Already marked OUT at ' || to_char(current_date + v_existing.out_time, 'HH24:MI'));
  END IF;

  v_hours := EXTRACT(EPOCH FROM (v_now - v_existing.in_time)) / 3600.0;
  UPDATE mcp_attendance
    SET out_time = v_now,
        hours_worked = round(v_hours::numeric, 2),
        captured_out_lat = p_lat, captured_out_lng = p_lng,
        captured_out_distance_m = round(v_distance, 1)
    WHERE id = v_existing.id;

  RETURN jsonb_build_object('success', true,
    'message', 'Marked OUT at ' || to_char(current_date + v_now, 'HH24:MI') || ' · ' || to_char(round(v_hours::numeric, 1), 'FM999.0') || ' hrs',
    'hours_worked', round(v_hours::numeric, 2));
END $function$;
