-- Project Costing is a plant-wide financial rollup (per-project spend across all
-- bills / invoices / expenses / petty cash) → grant it to management-tier builtin
-- roles only (plant_head / admin / manager), not line roles. Also keep the
-- seed_builtin_roles_for_plant function in step so new plants inherit it.
-- (Full function body applied live in migration rbac_project_costing_module; the
-- DB is the source of truth for the function.)
INSERT INTO public.role_permissions (role_id, module_key, action)
SELECT pr.id, 'project_costing', '*'
FROM public.plant_roles pr
WHERE pr.is_builtin AND pr.slug IN ('plant_head','admin','manager')
ON CONFLICT DO NOTHING;
