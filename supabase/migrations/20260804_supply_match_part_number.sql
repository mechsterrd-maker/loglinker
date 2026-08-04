-- Supersedes 20260801_supply_item_aliases' matcher.
--
-- WHY: the earlier matcher had fuzzy fallbacks (name-containment + shared-word
-- overlap) that mapped DIFFERENT parts onto one schedule line — e.g. a bill line
-- "MANIFOLD_53" and "MANIFOLD_4098" both landed on CPN 54SG4098 because they share
-- the word "manifold". For a plant, wrong supply credit is worse than no credit.
--
-- NEW RULE: match ONLY by part number. Evidence, strongest first:
--   tier 0  explicit user alias (the "Map items" override) — always wins
--   tier 1  bill item carries a customer_part_number that equals the line CPN
--   tier 2  bill item CPN is contained in the line CPN (>=4 chars)
--   tier 3  the numeric CODE printed in the item name (e.g. MANIFOLD_"53",
--           MANIFOLD_"4098") equals the trailing digits of the line's CPN
--           (54S300"53", 54SG"4098"). This is how KF prints Simpson part refs.
-- NO name / word-overlap tiers. If nothing matches on part number the item is
-- left UNMATCHED for the user to map by hand (or to re-scan with the number).
-- Ranking prefers the bill's own month, then the nearest required date.
create or replace function public.find_open_line_for_item(
  p_plant_id uuid, p_customer_id uuid, p_item_name text, p_item_part_number text, p_dispatch_date date)
 returns uuid language plpgsql stable
as $function$
declare
  v_line_id uuid;
  v_item_lower text;
  v_item_norm text;
  v_cpn text;     -- explicit part number captured on the bill item (may be blank)
  v_code text;    -- longest digit run (>=2) printed in the item name
  v_alias text;
begin
  if p_customer_id is null then return null; end if;
  v_item_lower := lower(coalesce(p_item_name, ''));
  v_item_norm  := btrim(regexp_replace(v_item_lower, '[^a-z0-9]+', ' ', 'g'));
  v_cpn        := btrim(lower(coalesce(p_item_part_number, '')));

  select (arr)[1] into v_code
  from regexp_matches(v_item_lower, '[0-9]{2,}', 'g') as t(arr)
  order by length((arr)[1]) desc, (arr)[1] desc
  limit 1;

  select target_part_name into v_alias
  from public.mcp_sched_item_aliases
  where plant_id = p_plant_id and customer_id = p_customer_id and external_norm = v_item_norm
  limit 1;

  if v_cpn = '' and v_code is null and v_alias is null then return null; end if;

  with base as (
    select l.id, lower(coalesce(l.customer_part_number,'')) as cpn,
      regexp_replace(coalesce(l.customer_part_number,''), '\D', '', 'g') as cpn_digits,
      lower(btrim(coalesce(l.part_name_raw,''))) as pname,
      (sc.schedule_month = date_trunc('month', p_dispatch_date)::date) as same_month,
      abs(coalesce(l.required_by_date, l.week_start_date) - p_dispatch_date) as date_dist
    from mcp_sched_lines l
    join mcp_sched_schedules sc on sc.id = l.schedule_id
    left join (select schedule_line_id, sum(supplied_qty) sup from mcp_sched_supplies group by schedule_line_id) s
      on s.schedule_line_id = l.id
    where l.plant_id = p_plant_id and sc.customer_id = p_customer_id
      and sc.status in ('active','open')
      and coalesce(s.sup, 0) < l.planned_qty
  ),
  cand as (
    select id, cpn, same_month, date_dist,
      case
        when v_alias is not null and pname = lower(btrim(v_alias)) then 0
        when v_cpn <> '' and cpn <> '' and cpn = v_cpn then 1
        when v_cpn <> '' and cpn <> '' and length(v_cpn) >= 4 and position(v_cpn in cpn) > 0 then 2
        when v_code is not null and cpn_digits <> '' and right(cpn_digits, length(v_code)) = v_code then 3
        else null
      end as tier
    from base
  ),
  best as (select min(tier) as tier from cand where tier is not null)
  -- Ambiguity guard: if the winning tier resolves to more than one DISTINCT part
  -- number (e.g. a short 2-digit code that happens to end two different CPNs),
  -- refuse to guess. Same part across several delivery dates shares one CPN, so
  -- that legitimate case still resolves.
  select id into v_line_id
  from cand
  where tier = (select tier from best)
    and (select count(distinct cpn) from cand where tier = (select tier from best)) = 1
  order by same_month desc, date_dist asc
  limit 1;
  return v_line_id;
end $function$;
