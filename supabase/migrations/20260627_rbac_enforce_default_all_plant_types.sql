-- Make the RBAC role matrix the default for EVERY plant type
-- (was: only fabrication + starter). Owners are never filtered and users
-- without an assigned role keep the legacy menu, so this only ACTIVATES the
-- capability — it does not restrict anyone until an admin assigns a role.

-- 1) New plants of any type: seed roles (unchanged) + enforce unconditionally.
CREATE OR REPLACE FUNCTION public.tg_plant_after_insert_rbac()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
begin
  perform public.seed_builtin_roles_for_plant(new.id);
  -- RBAC role matrix is now the default for all plant types.
  update public.plants set rbac_enforced = true where id = new.id;
  return new;
end;
$function$;

-- 2) Belt-and-braces: default the column to true for any insert path.
ALTER TABLE public.plants ALTER COLUMN rbac_enforced SET DEFAULT true;

-- 3) Bring existing plants still on the old default up to the new one.
UPDATE public.plants SET rbac_enforced = true WHERE rbac_enforced = false;
