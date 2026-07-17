-- Bug: a plant OWNER (legacy users.role = plant_head/admin) who is assigned a
-- CUSTOM RBAC role (e.g. "management", a slug not in the built-in whitelist) was
-- wrongly treated as project-restricted on RBAC plants. is_project_restricted()
-- only whitelisted the built-in slugs plant_head/admin/manager, so such an owner
-- could see only the documents / payments / expenses / petty-cash rows they had
-- personally created — every project-linked row from others was hidden by the
-- *_project_scope_sel RLS policies.
--
-- Symptom (Marvel Machines): "Druva Lakshman" — legacy plant_head, RBAC slug
-- 'management' — saw only 2 of 32 supplier invoices.
--
-- Fix: owners (legacy plant_head/admin) are never project-restricted, regardless
-- of their RBAC role. This only ever GRANTS an owner more visibility; it never
-- restricts anyone further.
CREATE OR REPLACE FUNCTION public.is_project_restricted(p_uid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.is_rbac_plant(p_uid)
     and coalesce((select role::text from public.users where id = p_uid), '') not in ('plant_head','admin')
     and not (public.my_role_slugs(p_uid) && array['plant_head','admin','manager']);
$function$;
