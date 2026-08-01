-- Remembered bill-item -> schedule-part mappings + a top-priority alias tier in
-- the matcher, so once a user maps an item on a bill (e.g. "ADAPTOR M002" ->
-- "Old adaptor") future bills auto-match it. Backs the on-bill "Map items" panel.
create table if not exists public.mcp_sched_item_aliases (
  id uuid primary key default gen_random_uuid(),
  plant_id uuid not null references public.plants(id) on delete cascade,
  customer_id uuid not null references public.mcp_sched_customers(id) on delete cascade,
  external_norm text not null,            -- normalized bill item name
  target_part_name text not null,         -- schedule line part_name_raw to credit
  created_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (plant_id, customer_id, external_norm)
);
alter table public.mcp_sched_item_aliases enable row level security;
drop policy if exists mcp_sched_item_aliases_sel on public.mcp_sched_item_aliases;
drop policy if exists mcp_sched_item_aliases_all on public.mcp_sched_item_aliases;
create policy mcp_sched_item_aliases_sel on public.mcp_sched_item_aliases for select to authenticated using (plant_id = my_plant_id());
create policy mcp_sched_item_aliases_all on public.mcp_sched_item_aliases for all to authenticated using (plant_id = my_plant_id()) with check (plant_id = my_plant_id());

create or replace function public.remember_item_alias(p_plant_id uuid, p_customer_id uuid, p_item_name text, p_part_name text)
returns void language plpgsql security definer set search_path=public as $$
declare v_norm text;
begin
  if p_customer_id is null or coalesce(btrim(p_item_name),'')='' or coalesce(btrim(p_part_name),'')='' then return; end if;
  if p_plant_id is distinct from my_plant_id() then return; end if;
  v_norm := btrim(regexp_replace(lower(p_item_name), '[^a-z0-9]+', ' ', 'g'));
  if v_norm = '' then return; end if;
  insert into public.mcp_sched_item_aliases(plant_id, customer_id, external_norm, target_part_name, created_by)
  values (p_plant_id, p_customer_id, v_norm, btrim(p_part_name), auth.uid())
  on conflict (plant_id, customer_id, external_norm) do update set target_part_name = excluded.target_part_name;
end $$;
grant execute on function public.remember_item_alias(uuid,uuid,text,text) to authenticated;

-- Matcher with a top-priority alias tier (0). Full definition (supersedes
-- 20260801_supply_match_token_overlap).
create or replace function public.find_open_line_for_item(p_plant_id uuid, p_customer_id uuid, p_item_name text, p_item_part_number text, p_dispatch_date date)
 returns uuid language plpgsql stable
as $function$
declare
  v_line_id uuid;
  v_item_lower text;
  v_item_norm text;
  v_item_alpha text;
  v_cpn text;
  v_alias text;
begin
  if p_customer_id is null then return null; end if;
  v_item_lower := lower(coalesce(p_item_name, ''));
  v_item_norm  := btrim(regexp_replace(v_item_lower, '[^a-z0-9]+', ' ', 'g'));
  v_item_alpha := btrim(regexp_replace(v_item_lower, '[^a-z]+',   ' ', 'g'));
  v_cpn        := lower(coalesce(p_item_part_number, ''));
  if v_item_norm = '' and v_cpn = '' then return null; end if;

  select target_part_name into v_alias
  from public.mcp_sched_item_aliases
  where plant_id = p_plant_id and customer_id = p_customer_id and external_norm = v_item_norm
  limit 1;

  with base as (
    select l.id, l.customer_part_number, l.part_name_raw,
      (sc.schedule_month = date_trunc('month', p_dispatch_date)::date) as same_month,
      abs(coalesce(l.required_by_date, l.week_start_date) - p_dispatch_date) as date_dist,
      (select count(*) from (
         select t from unnest(string_to_array(v_item_norm,' ')) t where length(t) >= 3
         intersect
         select t from unnest(string_to_array(btrim(regexp_replace(lower(coalesce(l.part_name_raw,'')),'[^a-z0-9]+',' ','g')),' ')) t where length(t) >= 3
       ) z) as tok_overlap
    from mcp_sched_lines l
    join mcp_sched_schedules sc on sc.id = l.schedule_id
    left join (select schedule_line_id, sum(supplied_qty) sup from mcp_sched_supplies group by schedule_line_id) s
      on s.schedule_line_id = l.id
    where l.plant_id = p_plant_id and sc.customer_id = p_customer_id
      and sc.status in ('active','open')
      and coalesce(s.sup, 0) < l.planned_qty
  ),
  cand as (
    select id, same_month, date_dist, tok_overlap,
      case
        when v_alias is not null and lower(btrim(coalesce(part_name_raw,''))) = lower(btrim(v_alias)) then 0
        when v_cpn <> '' and lower(coalesce(customer_part_number,'')) = v_cpn then 1
        when coalesce(customer_part_number,'') <> '' and length(customer_part_number) >= 4
             and position(lower(customer_part_number) in v_item_lower) > 0 then 2
        when length(coalesce(customer_part_number,'')) >= 3 and (
              (right(customer_part_number,3) ~ '^[0-9]{3}$'
               and position(' '||right(customer_part_number,3)||' ' in ' '||v_item_norm||' ') > 0)
           or (length(customer_part_number) >= 4 and right(customer_part_number,4) ~ '^[0-9]{4}$'
               and position(' '||right(customer_part_number,4)||' ' in ' '||v_item_norm||' ') > 0)
        ) then 3
        when length(v_item_alpha) >= 4 and coalesce(part_name_raw,'') <> ''
             and length(btrim(regexp_replace(lower(part_name_raw),'[^a-z]+',' ','g'))) >= 4
             and ( position(btrim(regexp_replace(lower(part_name_raw),'[^a-z]+',' ','g')) in v_item_alpha) > 0
                or position(v_item_alpha in btrim(regexp_replace(lower(part_name_raw),'[^a-z]+',' ','g'))) > 0 ) then 4
        when tok_overlap >= 2 then 5
        else null
      end as tier
    from base
  )
  select id into v_line_id from cand where tier is not null
  order by same_month desc, tier asc, tok_overlap desc, date_dist asc
  limit 1;
  return v_line_id;
end $function$;
