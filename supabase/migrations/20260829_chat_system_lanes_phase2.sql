-- Phase 2 of the chat reorg: route system posts into dedicated lane channels
-- (📄 Documents · ✅ Tasks & reminders · 🛠 Operations) instead of dumping every
-- cascade into All Hands. Applied via Supabase MCP; this is the tracked mirror.
--
-- Design: ~37 cascade_* / post_daily_* functions all funnel through the single
-- choke point post_to_all_hands(). Rather than touch all 37, we classify the
-- message body by its leading emoji and route to the right lane there. Anything
-- unclassified (human chat) falls back to All Hands, so it is safe by default.
-- Gated per-plant by plants.chat_lanes_enabled (Marvel only, for now).

alter table public.plants add column if not exists chat_lanes_enabled boolean not null default false;

-- Find-or-create a plant-wide system lane group, keeping membership current so
-- newly-joined staff also see the lane.
create or replace function public._ensure_lane_group(p_plant_id uuid, p_key text, p_name text)
returns uuid language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_members uuid[];
begin
  select coalesce(array_agg(id), '{}') into v_members
    from public.users where plant_id = p_plant_id and status = 'active';
  select id into v_id from public.chat_groups
    where plant_id = p_plant_id and metadata->>'lane' = p_key limit 1;
  if v_id is null then
    insert into public.chat_groups (plant_id, name, type, members, metadata, created_by)
    values (p_plant_id, p_name, 'custom', v_members,
            jsonb_build_object('lane', p_key, 'system', true),
            (select id from public.users where plant_id = p_plant_id and role in ('plant_head','admin') order by created_at limit 1))
    returning id into v_id;
  elsif exists (select 1 from public.chat_groups where id = v_id and members is distinct from v_members) then
    update public.chat_groups set members = v_members where id = v_id;
  end if;
  return v_id;
end $fn$;

-- Classify a system-post body by its leading emoji → lane key (null = All Hands).
create or replace function public._lane_for_body(p_body text)
returns text language plpgsql immutable as $fn$
declare b text := ltrim(coalesce(p_body, ''));
begin
  if b ~ '^(📋|📝|🗓|⚠️|⏰|🔴|🔔)' then return 'tasks'; end if;          -- digests, reminders, escalations
  if b ~ '^(📄|📑|📥|📤|📦|🧾|💰|💵|🛒)' then return 'documents'; end if; -- DC/invoice/GRN/stock/finance
  if b ~ '^(🔧|🛠|🏭|🧪|🔬|🔩|🏆|🎓|📞|✅|📅|🗂|🚨)' then return 'operations'; end if; -- breakdown/NCR/quality/NPD
  return null;
end $fn$;

-- Reroute the single choke point every cascade uses.
create or replace function public.post_to_all_hands(p_plant_id uuid, p_sender_id uuid, p_body text, p_unit_id uuid default null)
returns uuid language plpgsql security definer as $fn$
declare v_group_id uuid; v_grp record; v_ret uuid; v_lane text; v_name text; v_on boolean;
begin
  if p_plant_id is null or p_body is null or btrim(p_body) = '' then return null; end if;
  select coalesce(chat_lanes_enabled, false) into v_on from public.plants where id = p_plant_id;
  if v_on then
    v_lane := public._lane_for_body(p_body);
    v_name := case v_lane
                when 'tasks'      then '✅ Tasks & reminders'
                when 'documents'  then '📄 Documents'
                when 'operations' then '🛠 Operations'
                else null end;
    if v_name is not null then
      v_group_id := public._ensure_lane_group(p_plant_id, v_lane, v_name);
      if v_group_id is not null then
        return public._post_group_message(p_plant_id, v_group_id, p_sender_id, p_body);
      end if;
    end if;
  end if;
  -- Unclassified / lanes off → original behaviour (unit group, else All Hands).
  if p_unit_id is not null then
    select id into v_group_id from public.chat_groups where plant_id = p_plant_id and unit_ids = array[p_unit_id] order by created_at limit 1;
  end if;
  if v_group_id is null then
    select id into v_group_id from public.chat_groups where plant_id = p_plant_id and type = 'all_hands' order by created_at limit 1;
  end if;
  if v_group_id is not null then
    return public._post_group_message(p_plant_id, v_group_id, p_sender_id, p_body);
  end if;
  for v_grp in select id from public.chat_groups where plant_id = p_plant_id and array_length(unit_ids, 1) = 1 loop
    v_ret := public._post_group_message(p_plant_id, v_grp.id, p_sender_id, p_body);
  end loop;
  return v_ret;
end $fn$;

-- Enable for Marvel, and pre-create its three lanes so they appear immediately.
update public.plants set chat_lanes_enabled = true where id = 'b1f10825-75e0-4a83-8de8-8941f47e5928';
select public._ensure_lane_group('b1f10825-75e0-4a83-8de8-8941f47e5928','tasks','✅ Tasks & reminders');
select public._ensure_lane_group('b1f10825-75e0-4a83-8de8-8941f47e5928','documents','📄 Documents');
select public._ensure_lane_group('b1f10825-75e0-4a83-8de8-8941f47e5928','operations','🛠 Operations');
