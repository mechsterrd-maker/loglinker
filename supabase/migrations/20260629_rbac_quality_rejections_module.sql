-- Grant builtin roles access to the new quality_rejections module, and keep the
-- seed function in step so newly created plants get it too.

-- 1) Backfill existing builtin roles.
--    plant_head / admin / manager -> full ('*'); supervisor -> view+create+edit.
INSERT INTO public.role_permissions (role_id, module_key, action)
SELECT pr.id, 'quality_rejections', '*'
FROM public.plant_roles pr
WHERE pr.is_builtin AND pr.slug IN ('plant_head','admin','manager')
ON CONFLICT DO NOTHING;

INSERT INTO public.role_permissions (role_id, module_key, action)
SELECT pr.id, 'quality_rejections', a_
FROM public.plant_roles pr, unnest(array['view','create','edit']) a_
WHERE pr.is_builtin AND pr.slug = 'supervisor'
ON CONFLICT DO NOTHING;

-- 2) seed_builtin_roles_for_plant updated to include 'quality_rejections' in the
--    plant_head / admin / manager full-access arrays and supervisor view+edit
--    arrays. See applied migration rbac_quality_rejections_module for the full
--    function body (kept in the DB as the source of truth).
