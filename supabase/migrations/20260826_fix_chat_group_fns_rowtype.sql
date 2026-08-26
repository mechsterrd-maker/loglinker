-- The chat-group management RPCs (update/add member/remove member/delete/set admin)
-- declared v_group as a generic `record` and passed it to
-- can_manage_chat_group(p_group chat_groups, ...) — which failed at runtime with
-- "cannot cast type record to chat_groups", so editing a group / managing members
-- errored. Fix: declare v_group as chat_groups%ROWTYPE so the call type-checks.
-- Only the DECLARE line changed in each function. Applied live; file keeps repo in sync.

CREATE OR REPLACE FUNCTION public.update_chat_group(p_group_id uuid, p_name text, p_description text, p_icon_url text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
declare v_uid uuid; v_role user_role; v_group chat_groups%ROWTYPE;
begin
  v_uid := auth.uid();
  select role into v_role from users where id = v_uid;
  select * into v_group from chat_groups where id = p_group_id;
  if v_group is null then return jsonb_build_object('success', false, 'error', 'Group not found'); end if;
  if not public.can_manage_chat_group(v_group, v_uid, v_role) then
    return jsonb_build_object('success', false, 'error', 'Only group admins can edit the group');
  end if;
  update chat_groups
     set name        = coalesce(nullif(trim(p_name), ''), name),
         description = p_description,
         icon_url    = p_icon_url
   where id = p_group_id;
  return jsonb_build_object('success', true);
end $function$;

CREATE OR REPLACE FUNCTION public.add_group_member(p_group_id uuid, p_user_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
declare v_uid uuid; v_role user_role; v_group chat_groups%ROWTYPE; v_name text;
begin
  v_uid := auth.uid();
  select role into v_role from users where id = v_uid;
  select * into v_group from chat_groups where id = p_group_id;
  if v_group is null then return jsonb_build_object('success', false, 'error', 'Group not found'); end if;
  if not public.can_manage_chat_group(v_group, v_uid, v_role) then
    return jsonb_build_object('success', false, 'error', 'Only group admins can add members');
  end if;
  if p_user_id = any(v_group.members) then
    return jsonb_build_object('success', false, 'error', 'Already a member');
  end if;
  update chat_groups set members = array_append(members, p_user_id) where id = p_group_id;
  select full_name into v_name from users where id = p_user_id;
  insert into chat_messages (plant_id, group_id, sender_id, body)
  values (v_group.plant_id, p_group_id, v_uid, '👥 ' || v_name || ' was added to the group');
  return jsonb_build_object('success', true);
end $function$;

CREATE OR REPLACE FUNCTION public.delete_chat_group(p_group_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
declare v_uid uuid; v_role user_role; v_group chat_groups%ROWTYPE;
begin
  v_uid := auth.uid();
  select role into v_role from users where id = v_uid;
  select * into v_group from chat_groups where id = p_group_id;
  if v_group is null then return jsonb_build_object('success', false, 'error', 'Group not found'); end if;
  if not public.can_manage_chat_group(v_group, v_uid, v_role) then
    return jsonb_build_object('success', false, 'error', 'Only group admins can delete the group');
  end if;
  delete from chat_messages where group_id = p_group_id;
  delete from chat_groups where id = p_group_id;
  return jsonb_build_object('success', true);
end $function$;

CREATE OR REPLACE FUNCTION public.remove_group_member(p_group_id uuid, p_user_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
declare v_uid uuid; v_role user_role; v_group chat_groups%ROWTYPE; v_name text;
begin
  v_uid := auth.uid();
  select role into v_role from users where id = v_uid;
  select * into v_group from chat_groups where id = p_group_id;
  if v_group is null then return jsonb_build_object('success', false, 'error', 'Group not found'); end if;
  if p_user_id <> v_uid and not public.can_manage_chat_group(v_group, v_uid, v_role) then
    return jsonb_build_object('success', false, 'error', 'Not allowed to remove others');
  end if;
  if not (p_user_id = any(v_group.members)) then
    return jsonb_build_object('success', false, 'error', 'Not a member');
  end if;
  update chat_groups
     set members = array_remove(members, p_user_id),
         admins  = array_remove(coalesce(admins,'{}'::uuid[]), p_user_id)
   where id = p_group_id;
  select full_name into v_name from users where id = p_user_id;
  insert into chat_messages (plant_id, group_id, sender_id, body)
  values (v_group.plant_id, p_group_id, v_uid,
    case when p_user_id = v_uid then '👋 ' || v_name || ' left the group'
         else '👥 ' || v_name || ' was removed from the group' end);
  return jsonb_build_object('success', true);
end $function$;

CREATE OR REPLACE FUNCTION public.set_group_admin(p_group_id uuid, p_user_id uuid, p_make_admin boolean)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
declare v_uid uuid; v_role user_role; v_group chat_groups%ROWTYPE; v_name text;
begin
  v_uid := auth.uid();
  select role into v_role from users where id = v_uid;
  select * into v_group from chat_groups where id = p_group_id;
  if v_group is null then return jsonb_build_object('success', false, 'error', 'Group not found'); end if;
  if not public.can_manage_chat_group(v_group, v_uid, v_role) then
    return jsonb_build_object('success', false, 'error', 'Only group admins can change admins');
  end if;
  if not (p_user_id = any(v_group.members)) then
    return jsonb_build_object('success', false, 'error', 'User is not a member');
  end if;
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
