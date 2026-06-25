-- Payroll v2: shift timings, short-time settlement, and allowances.
--
-- shift_start / shift_end define the daily window (9:00–17:30 = 8.5h). Net of
-- per-day (worked − shift) is settled monthly: positive → overtime, negative →
-- short-time (deducted at the regular hourly rate, after the permission
-- allowance). permission_hours forgive short-time; paid_leave_days forgive
-- leave before any loss-of-pay applies.
ALTER TABLE public.mcp_payroll_config
  ADD COLUMN IF NOT EXISTS shift_start      time,
  ADD COLUMN IF NOT EXISTS shift_end        time,
  ADD COLUMN IF NOT EXISTS permission_hours numeric(5,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS paid_leave_days  numeric(5,2) DEFAULT 0;
