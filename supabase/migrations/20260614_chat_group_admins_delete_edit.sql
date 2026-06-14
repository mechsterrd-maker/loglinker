-- WhatsApp-style group management: per-group admins, editable name/desc/icon,
-- group deletion. admins[] holds promoted members; creator is always an admin.
alter table public.chat_groups
  add column if not exists admins uuid[] not null default '{}'::uuid[],
  add column if not exists description text,
  add column if not exists icon_url text;

create or replace function public.can_manage_chat_group(p_group chat_groups, p_uid uuid, p_role user_role)
returns boolean language sql immutable as $$
  select p_group.created_by is not distinct from p_uid
      or p_uid = any(coalesce(p_group.admins, '{}'::uuid[]))
      or p_role in ('plant_head','admin');
$$;

create or replace function public.set_group_admin(p_group_id uuid, p_user_id uuid, p_make_admin boolean)
returns jsonb language plpgsql security definer as $function$
declare v_uid uuid; v_role user_role; v_group record; v_name text;
begin
  v_uid := auth.uid();
  select role into v_role from users where id = v_uid;
  select * into v_group from chat_groups where id = p_group_id;
  if v_group is null then return jsonb_build_object('success', false, 'error', 'Group not found'); end if;
  if not public.can_manage_chat_group(v_group, v_uid, v_role) then
    return jsonb_build_object('success', false, 'error', 'Only group admins can change admins'); end if;
  if not (p_user_id = any(v_group.members)) then
    return jsonb_build_object('success', false, 'error', 'User is not a member'); end if;
  if p_make_admin then
    update chat_groups set admins = (select array(select distinct unnest(array_append(coalesce(admins,'{}'),p_user_id)))) where id = p_group_id;
  else
    update chat_groups set admins = array_remove(coalesce(admins,'{}'), p_user_id) where id = p_group_id;
  end if;
  select full_name into v_name from users where id = p_user_id;
  insert into chat_messages (plant_id, group_id, sender_id, body)
  values (v_group.plant_id, p_group_id, v_uid, '👑 ' || coalesce(v_name,'A member') || (case when p_make_admin then ' is now a group admin' else ' is no longer a group admin' end));
  return jsonb_build_object('success', true);
end $function$;

create or replace function public.update_chat_group(p_group_id uuid, p_name text, p_description text, p_icon_url text)
returns jsonb language plpgsql security definer as $function$
declare v_uid uuid; v_role user_role; v_group record;
begin
  v_uid := auth.uid();
  select role into v_role from users where id = v_uid;
  select * into v_group from chat_groups where id = p_group_id;
  if v_group is null then return jsonb_build_object('success', false, 'error', 'Group not found'); end if;
  if not public.can_manage_chat_group(v_group, v_uid, v_role) then
    return jsonb_build_object('success', false, 'error', 'Only group admins can edit the group'); end if;
  update chat_groups set name = coalesce(nullif(trim(p_name), ''), name), description = p_description, icon_url = p_icon_url where id = p_group_id;
  return jsonb_build_object('success', true);
end $function$;

create or replace function public.delete_chat_group(p_group_id uuid)
returns jsonb language plpgsql security definer as $function$
declare v_uid uuid; v_role user_role; v_group record;
begin
  v_uid := auth.uid();
  select role into v_role from users where id = v_uid;
  select * into v_group from chat_groups where id = p_group_id;
  if v_group is null then return jsonb_build_object('success', false, 'error', 'Group not found'); end if;
  if not public.can_manage_chat_group(v_group, v_uid, v_role) then
    return jsonb_build_object('success', false, 'error', 'Only group admins can delete the group'); end if;
  delete from chat_messages where group_id = p_group_id;
  delete from chat_groups where id = p_group_id;
  return jsonb_build_object('success', true);
end $function$;

-- add/remove member RPCs updated to honour group admins (see app history).
