-- Per schedule line (part x delivery date), the quantity the plant PLANS to supply
-- back to the customer. Prefilled from the demand (planned_qty), edited in the
-- Supply Planner, and exported in the schedule's grid format to send the customer.
alter table public.mcp_sched_lines add column if not exists supply_plan_qty numeric;
