-- Store thickness per stock item in a dedicated thickness_mm column so it's
-- queryable/exportable, and keep it in sync automatically. Value comes from the
-- section's "Thk" dimension when structured, else parsed from the name/size
-- text ("Thk 22mm", "6.6 THK", leading "3MM …") for Excel-imported items.
alter table public.mcp_stocks_items add column if not exists thickness_mm numeric;

create or replace function public.sync_stock_thickness()
returns trigger language plpgsql as $function$
declare txt text; v numeric;
begin
  v := case
    when NEW.section_type = 'angle' then NEW.dim3
    when NEW.section_type in ('flat','shs') then NEW.dim2
    when NEW.section_type in ('plate','sheet','coil') then NEW.dim1
    when NEW.section_type = 'rhs' then NEW.dim3
    else null
  end;
  if v is null then
    txt := lower(coalesce(NEW.name,'') || ' ' || coalesce(NEW.size_spec,''));
    v := coalesce(
      substring(txt from '(?:thk|thickness)\s*[:=]?\s*([0-9]+(?:\.[0-9]+)?)')::numeric,
      substring(txt from '([0-9]+(?:\.[0-9]+)?)\s*(?:mm)?\s*(?:thk|thickness)')::numeric,
      substring(txt from '^\s*([0-9]+(?:\.[0-9]+)?)\s*mm')::numeric
    );
  end if;
  NEW.thickness_mm := v;
  return NEW;
end $function$;

drop trigger if exists trg_sync_stock_thickness on public.mcp_stocks_items;
create trigger trg_sync_stock_thickness
  before insert or update of section_type, dim1, dim2, dim3, name, size_spec
  on public.mcp_stocks_items
  for each row execute function public.sync_stock_thickness();

-- One-time backfill (same logic as the trigger).
update public.mcp_stocks_items
set thickness_mm = coalesce(
    case when section_type='angle' then dim3
         when section_type in ('flat','shs') then dim2
         when section_type in ('plate','sheet','coil') then dim1
         when section_type='rhs' then dim3 end,
    substring(lower(coalesce(name,'')||' '||coalesce(size_spec,'')) from '(?:thk|thickness)\s*[:=]?\s*([0-9]+(?:\.[0-9]+)?)')::numeric,
    substring(lower(coalesce(name,'')||' '||coalesce(size_spec,'')) from '([0-9]+(?:\.[0-9]+)?)\s*(?:mm)?\s*(?:thk|thickness)')::numeric,
    substring(lower(coalesce(name,'')) from '^\s*([0-9]+(?:\.[0-9]+)?)\s*mm')::numeric
  )
where category='raw_material';
