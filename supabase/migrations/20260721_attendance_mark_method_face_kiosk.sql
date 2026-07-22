-- The face-kiosk punch RPC writes mcp_attendance with mark_method='face_kiosk',
-- but the column's CHECK constraint didn't allow that value (only supervisor /
-- self_gps_qr / self_onduty), so kiosk punches failed. Add 'face_kiosk'.
ALTER TABLE public.mcp_attendance DROP CONSTRAINT IF EXISTS mcp_attendance_mark_method_check;
ALTER TABLE public.mcp_attendance ADD CONSTRAINT mcp_attendance_mark_method_check
  CHECK (mark_method = ANY (ARRAY['supervisor'::text, 'self_gps_qr'::text, 'self_onduty'::text, 'face_kiosk'::text]));
