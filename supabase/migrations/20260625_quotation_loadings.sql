-- Quotation loadings & margin. Percentages cascade on the running subtotal in
-- the order: rejection -> inward transport -> supply transport -> packing ->
-- inspection -> overhead -> profit. Transports are lump sums for the lot,
-- divided by qty to a per-piece figure. grand_total = final per-piece price.
ALTER TABLE public.mcp_quotations
  ADD COLUMN IF NOT EXISTS rej_pct          numeric DEFAULT 2,
  ADD COLUMN IF NOT EXISTS packing_pct      numeric DEFAULT 3,
  ADD COLUMN IF NOT EXISTS inspection_pct   numeric DEFAULT 0.5,
  ADD COLUMN IF NOT EXISTS overhead_pct     numeric DEFAULT 5,
  ADD COLUMN IF NOT EXISTS profit_pct       numeric DEFAULT 10,
  ADD COLUMN IF NOT EXISTS inward_transport numeric DEFAULT 0,
  ADD COLUMN IF NOT EXISTS supply_transport numeric DEFAULT 0;
