-- Per-unit data isolation — FOUNDATION.
-- Each unit is a separate factory; units do not share data. Owners/MD and
-- all-unit managers see every unit; unit staff are locked to their own.
-- These two functions are the access primitives used by the RLS policies.

-- The set of unit_ids the current user may access. Owners (plant_head/admin)
-- and anyone granted all units see every unit in their plant; everyone else
-- sees only the units explicitly granted to them (+ their primary unit).
CREATE OR REPLACE FUNCTION public.my_unit_ids()
RETURNS uuid[]
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid(); v_plant uuid; v_role text;
begin
  if v_uid is null then return array[]::uuid[]; end if;
  select plant_id, role::text into v_plant, v_role from public.users where id = v_uid;
  if v_plant is null then return array[]::uuid[]; end if;
  if v_role in ('plant_head','admin') then
    return array(select id from public.units where plant_id = v_plant);
  end if;
  return array(
    select distinct uid from (
      select unit_id as uid from public.user_unit_access where user_id = v_uid
      union
      select primary_unit_id from public.users where id = v_uid and primary_unit_id is not null
    ) s where uid is not null
  );
end;
$function$;

-- Is a given unit_id visible to me? NULL = shared/common (visible in every unit).
CREATE OR REPLACE FUNCTION public.unit_visible(p_unit_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT p_unit_id IS NULL OR p_unit_id = ANY(public.my_unit_ids());
$function$;
