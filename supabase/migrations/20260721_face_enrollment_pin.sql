-- Face kiosk reliability: optional backup PIN per enrollment. When the camera
-- can't get a clean match (bad light, mask, glare), the worker punches with a
-- 4–6 digit PIN they set at enrollment. The PIN is a fallback, not a login —
-- it only drives a kiosk punch on the already-authenticated gate device.
-- Enrollment also now stores MULTIPLE face descriptors (samples at slightly
-- different angles); the existing `descriptors jsonb` array already holds them.

ALTER TABLE public.attendance_face_enrollments
  ADD COLUMN IF NOT EXISTS pin text;
