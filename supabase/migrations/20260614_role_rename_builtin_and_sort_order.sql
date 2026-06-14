-- Allow renaming the DISPLAY name of built-in roles (code references slug,
-- not display_name) and add hierarchy ranking via sort_order.
create or replace function public.update_plant_role(
  p_role_id uuid, p_display_name text, p_description text,
  p_is_active boolean, p_sort_order int default null
) returns void language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid(); v_role record; v_caller_role text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select * into v_role from public.plant_roles where id = p_role_id;
  if v_role.id is null then raise exception 'role_not_found'; end if;
  select role::text into v_caller_role from public.users where id = v_uid and plant_id = v_role.plant_id;
  if v_caller_role not in ('plant_head','admin') then raise exception 'forbidden'; end if;
  if v_role.is_builtin then
    update public.plant_roles
       set display_name = coalesce(nullif(trim(p_display_name), ''), display_name),
           description  = coalesce(p_description, description),
           sort_order   = coalesce(p_sort_order, sort_order),
           updated_at   = now()
     where id = p_role_id;
  else
    update public.plant_roles
       set display_name = coalesce(nullif(trim(p_display_name), ''), display_name),
           description  = coalesce(p_description, description),
           is_active    = coalesce(p_is_active, is_active),
           sort_order   = coalesce(p_sort_order, sort_order),
           updated_at   = now()
     where id = p_role_id;
  end if;
end;
$function$;
