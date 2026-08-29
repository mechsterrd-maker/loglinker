-- Phase 3A of the chat reorg: a dedicated chat channel per project. Membership =
-- project team (leader/manager/supervisors) + owner + plant_head/admin. Gated to
-- plants with chat_lanes_enabled (Marvel). New projects get a channel via an
-- insert trigger; team changes re-sync membership; existing projects are
-- backfilled at the bottom. Applied via Supabase MCP; this is the tracked mirror.

create or replace function public._ensure_project_channel(p_project_id uuid)
returns uuid language plpgsql security definer set search_path=public as $fn$
declare v_id uuid; v_plant uuid; v_name text; v_code text; v_members uuid[];
begin
  select plant_id, name, code into v_plant, v_name, v_code from public.mcp_projects where id = p_project_id;
  if v_plant is null then return null; end if;
  if not coalesce((select chat_lanes_enabled from public.plants where id = v_plant), false) then return null; end if;

  select coalesce(array_agg(distinct uid), '{}') into v_members from (
    select user_id as uid from public.mcp_project_members where project_id = p_project_id
    union select owner_user_id from public.mcp_projects where id = p_project_id and owner_user_id is not null
    union select id from public.users where plant_id = v_plant and role in ('plant_head','admin') and status = 'active'
  ) t where uid is not null;

  select id into v_id from public.chat_groups
    where plant_id = v_plant and metadata->>'project_id' = p_project_id::text limit 1;
  if v_id is null then
    insert into public.chat_groups (plant_id, name, type, members, metadata, created_by)
    values (v_plant,
            '# ' || coalesce(nullif(v_code, '') || ' · ', '') || coalesce(nullif(v_name,''), 'Project'),
            'custom', v_members,
            jsonb_build_object('project_id', p_project_id::text, 'system', true),
            (select id from public.users where plant_id = v_plant and role in ('plant_head','admin') order by created_at limit 1))
    returning id into v_id;
  elsif exists (select 1 from public.chat_groups where id = v_id and members is distinct from v_members) then
    update public.chat_groups set members = v_members where id = v_id;
  end if;
  return v_id;
end $fn$;

create or replace function public._trg_project_channel() returns trigger language plpgsql security definer as $fn$
begin perform public._ensure_project_channel(new.id); return new; end $fn$;
drop trigger if exists project_channel_on_insert on public.mcp_projects;
create trigger project_channel_on_insert after insert on public.mcp_projects
  for each row execute function public._trg_project_channel();

create or replace function public._trg_project_member_channel() returns trigger language plpgsql security definer as $fn$
begin perform public._ensure_project_channel(coalesce(new.project_id, old.project_id)); return coalesce(new, old); end $fn$;
drop trigger if exists project_member_channel_sync on public.mcp_project_members;
create trigger project_member_channel_sync after insert or delete on public.mcp_project_members
  for each row execute function public._trg_project_member_channel();

do $$ declare r record; begin
  for r in select id from public.mcp_projects
           where plant_id = 'b1f10825-75e0-4a83-8de8-8941f47e5928' and coalesce(status,'') <> 'cancelled' loop
    perform public._ensure_project_channel(r.id);
  end loop;
end $$;
