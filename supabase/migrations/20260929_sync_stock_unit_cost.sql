-- Stock Value (qty × unit_cost) showed "—" for raw-material items that had a
-- ₹/kg rate AND a weight but whose unit_cost was never derived (Excel import,
-- price set outside the item form, receiving, etc.). unit_cost is the canonical
-- field used by the stock list, reports and project expenses, so fill it in.

-- 1) One-time backfill: unit_cost = ₹/kg × weight wherever it's derivable but 0/null.
update public.mcp_stocks_items
set unit_cost = round((rate_per_kg * unit_weight)::numeric, 2)
where rate_per_kg is not null and rate_per_kg > 0
  and unit_weight is not null and unit_weight > 0
  and coalesce(unit_cost, 0) = 0;

-- 2) Keep it in sync going forward: whenever ₹/kg or weight is set/changed,
--    recompute unit_cost. Only touches ₹/kg-priced items (rate_per_kg not null),
--    so directly-priced items (die spares/tools, rate_per_kg null) are untouched.
create or replace function public.sync_stock_unit_cost()
returns trigger language plpgsql as $function$
begin
  if NEW.rate_per_kg is not null and NEW.rate_per_kg > 0
     and NEW.unit_weight is not null and NEW.unit_weight > 0 then
    NEW.unit_cost := round((NEW.rate_per_kg * NEW.unit_weight)::numeric, 2);
  end if;
  return NEW;
end $function$;

drop trigger if exists trg_sync_stock_unit_cost on public.mcp_stocks_items;
create trigger trg_sync_stock_unit_cost
  before insert or update of rate_per_kg, unit_weight on public.mcp_stocks_items
  for each row execute function public.sync_stock_unit_cost();
