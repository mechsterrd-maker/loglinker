-- Marvel: "give me an option to delete it" (custom roles). Hard-delete a
-- non-builtin role that has no members. Built-in roles and roles still
-- assigned to users are protected.
create or replace function public.delete_plant_role(p_role_id uuid)
returns void language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_caller uuid := auth.uid(); v_caller_plant uuid; v_caller_role text;
  v_role record; v_members int;
begin
  if v_caller is null then raise exception 'not_authenticated'; end if;
  select plant_id, role::text into v_caller_plant, v_caller_role from public.users where id = v_caller;
  if v_caller_role not in ('plant_head','admin') then raise exception 'forbidden: plant_head/admin only'; end if;
  select * into v_role from public.plant_roles where id = p_role_id;
  if v_role.id is null then raise exception 'role_not_found'; end if;
  if v_role.plant_id <> v_caller_plant then raise exception 'forbidden: different plant'; end if;
  if v_role.is_builtin then raise exception 'Built-in roles cannot be deleted.'; end if;
  select count(*) into v_members from public.user_plant_roles where role_id = p_role_id;
  if v_members > 0 then
    raise exception 'This role still has % member(s). Reassign them to another role first.', v_members;
  end if;
  delete from public.role_permissions where role_id = p_role_id;
  delete from public.plant_roles where id = p_role_id;
end;
$function$;
