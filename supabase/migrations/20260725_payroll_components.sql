-- Optional structured salary: earnings (Basic/HRA/allowances) + deductions
-- (PF/ESI/PT/advance/custom). When null, payroll stays FLAT on monthly_salary
-- (unchanged behaviour). Shape:
--   { "earnings":   [{ "label":"Basic", "amount":12000 }, ...],
--     "deductions": [{ "label":"PF", "kind":"pct_basic", "value":12, "maxGross":null }, ...] }
-- kind in fixed | pct_basic | pct_gross ; maxGross skips the line when gross exceeds it (ESI <= 21000).
ALTER TABLE public.mcp_payroll_config
  ADD COLUMN IF NOT EXISTS components jsonb;
