-- Standalone HR app: employees are plain user records (login_enabled = false, no
-- auth account) managed by a single admin. Add the lightweight detail fields the
-- HR app collects on top of what users already has (phone, blood_group,
-- designation, employee_id): postal address, joining date, and monthly salary
-- (salary lives on the employee so payslips/payroll read it directly).
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS address        text,
  ADD COLUMN IF NOT EXISTS date_of_joining date,
  ADD COLUMN IF NOT EXISTS monthly_salary  numeric;
