-- Geofence + QR-anchored self-attendance.
ALTER TABLE public.plants
  ADD COLUMN IF NOT EXISTS geofence_lat       numeric(10,7),
  ADD COLUMN IF NOT EXISTS geofence_lng       numeric(10,7),
  ADD COLUMN IF NOT EXISTS geofence_radius_m  integer NOT NULL DEFAULT 150,
  ADD COLUMN IF NOT EXISTS attendance_qr_secret text,
  ADD COLUMN IF NOT EXISTS attendance_mode    text NOT NULL DEFAULT 'supervisor';

ALTER TABLE public.plants
  DROP CONSTRAINT IF EXISTS plants_attendance_mode_check;
ALTER TABLE public.plants
  ADD CONSTRAINT plants_attendance_mode_check
  CHECK (attendance_mode IN ('supervisor', 'self_gps_qr'));

ALTER TABLE public.mcp_attendance
  ADD COLUMN IF NOT EXISTS captured_in_lat       numeric(10,7),
  ADD COLUMN IF NOT EXISTS captured_in_lng       numeric(10,7),
  ADD COLUMN IF NOT EXISTS captured_in_distance_m numeric(8,2),
  ADD COLUMN IF NOT EXISTS captured_out_lat      numeric(10,7),
  ADD COLUMN IF NOT EXISTS captured_out_lng      numeric(10,7),
  ADD COLUMN IF NOT EXISTS captured_out_distance_m numeric(8,2),
  ADD COLUMN IF NOT EXISTS mark_method            text NOT NULL DEFAULT 'supervisor';

ALTER TABLE public.mcp_attendance
  DROP CONSTRAINT IF EXISTS mcp_attendance_mark_method_check;
ALTER TABLE public.mcp_attendance
  ADD CONSTRAINT mcp_attendance_mark_method_check
  CHECK (mark_method IN ('supervisor', 'self_gps_qr'));

CREATE OR REPLACE FUNCTION public.haversine_m(
  lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric
) RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  R   constant numeric := 6371000;
  dlat numeric; dlng numeric; a numeric; c numeric;
BEGIN
  IF lat1 IS NULL OR lng1 IS NULL OR lat2 IS NULL OR lng2 IS NULL THEN RETURN NULL; END IF;
  dlat := radians(lat2 - lat1);
  dlng := radians(lng2 - lng1);
  a := sin(dlat/2)*sin(dlat/2) + cos(radians(lat1))*cos(radians(lat2)) * sin(dlng/2)*sin(dlng/2);
  c := 2 * atan2(sqrt(a), sqrt(1-a));
  RETURN R * c;
END $$;

CREATE OR REPLACE FUNCTION public.regenerate_attendance_qr(p_plant_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_new text; v_role text;
BEGIN
  SELECT role::text INTO v_role FROM users WHERE id = auth.uid() AND plant_id = p_plant_id;
  IF v_role NOT IN ('plant_head', 'admin') THEN
    RAISE EXCEPTION 'Only plant head / admin can regenerate the attendance QR';
  END IF;
  -- gen_random_uuid() is built into Postgres 13+ (no pgcrypto needed).
  -- Two UUIDs concatenated → 64 hex chars: plenty of entropy for a QR.
  v_new := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  UPDATE plants SET attendance_qr_secret = v_new WHERE id = p_plant_id;
  RETURN v_new;
END $$;

CREATE OR REPLACE FUNCTION public.attendance_self_mark_in(
  p_plant_id uuid, p_qr text, p_lat numeric, p_lng numeric
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_plant plants; v_user_id uuid := auth.uid(); v_distance numeric; v_existing mcp_attendance;
BEGIN
  IF v_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Not authenticated'); END IF;
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
      RETURN jsonb_build_object('success', false, 'error', 'Already marked IN today at ' || to_char(v_existing.in_time, 'HH24:MI'));
    END IF;
    UPDATE mcp_attendance
      SET in_time = current_time,
          status = CASE WHEN status = 'absent' THEN 'present' ELSE status END,
          captured_in_lat = p_lat, captured_in_lng = p_lng,
          captured_in_distance_m = round(v_distance, 1),
          mark_method = 'self_gps_qr', marked_by = v_user_id
      WHERE id = v_existing.id;
  ELSE
    INSERT INTO mcp_attendance (plant_id, user_id, date, status, in_time,
        captured_in_lat, captured_in_lng, captured_in_distance_m, mark_method, marked_by)
      VALUES (p_plant_id, v_user_id, current_date, 'present', current_time,
              p_lat, p_lng, round(v_distance, 1), 'self_gps_qr', v_user_id);
  END IF;
  RETURN jsonb_build_object('success', true, 'message', 'Marked IN at ' || to_char(current_time, 'HH24:MI'),
    'distance_m', round(v_distance, 1));
END $$;

CREATE OR REPLACE FUNCTION public.attendance_self_mark_out(
  p_plant_id uuid, p_qr text, p_lat numeric, p_lng numeric
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_plant plants; v_user_id uuid := auth.uid(); v_distance numeric; v_existing mcp_attendance; v_hours numeric;
BEGIN
  IF v_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Not authenticated'); END IF;
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
    RETURN jsonb_build_object('success', false, 'error',
      format('You appear to be %s m from the factory', round(v_distance)), 'distance_m', round(v_distance, 1));
  END IF;
  SELECT * INTO v_existing FROM mcp_attendance
   WHERE plant_id = p_plant_id AND user_id = v_user_id AND date = current_date;
  IF NOT FOUND OR v_existing.in_time IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No IN punch found for today');
  END IF;
  IF v_existing.out_time IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Already marked OUT at ' || to_char(v_existing.out_time, 'HH24:MI'));
  END IF;
  v_hours := EXTRACT(EPOCH FROM (current_time - v_existing.in_time)) / 3600.0;
  UPDATE mcp_attendance
    SET out_time = current_time, hours_worked = round(v_hours::numeric, 2),
        captured_out_lat = p_lat, captured_out_lng = p_lng,
        captured_out_distance_m = round(v_distance, 1)
    WHERE id = v_existing.id;
  RETURN jsonb_build_object('success', true,
    'message', 'Marked OUT at ' || to_char(current_time, 'HH24:MI') || ' · ' || to_char(v_hours, 'FM999.0') || ' hrs',
    'hours_worked', round(v_hours::numeric, 2));
END $$;

-- Extend Starter Pack defaults to include the self-mark + setup tabs.
CREATE OR REPLACE FUNCTION public.plants_apply_business_type_defaults()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.business_type = 'starter' THEN
    IF NEW.enabled_tabs IS NULL THEN
      NEW.enabled_tabs := ARRAY['self_attendance', 'attendance', 'attendance_setup', 'petty_cash', 'actions'];
    END IF;
    IF NEW.quick_entry_tiles IS NULL THEN
      NEW.quick_entry_tiles := ARRAY['self_attendance', 'petty_cash', 'actions'];
    END IF;
    IF COALESCE(NEW.approval_status, 'pending') = 'pending' THEN
      NEW.approval_status := 'approved';
      IF NEW.approval_decided_at IS NULL THEN
        NEW.approval_decided_at := now();
      END IF;
      IF NEW.approval_note IS NULL THEN
        NEW.approval_note := 'Auto-approved · Starter Pack (no payment gate)';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;
