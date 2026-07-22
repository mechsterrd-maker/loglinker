-- Make the Tool & Insert Planner available on every plant (incl. manufacturing).
-- The module carries no business-type gate, so it already shows for all plant
-- types; this migration ensures RBAC visibility:
--   1) grant 'tooling' to every existing built-in role (done in 20260721_tooling_module)
--   2) add 'tooling' to seed_builtin_roles_for_plant so NEW plants inherit it:
--      plant_head / admin / manager → full; supervisor → view+create+edit;
--      operator → view+create (floor staff log daily wear / breakage).
-- Full CREATE OR REPLACE applied live via the Supabase MCP (rbac_tooling_seed);
-- the database is the source of truth for the function body. This file records
-- the intent + the additive backfill below for traceability.

INSERT INTO public.role_permissions (role_id, module_key, action)
SELECT pr.id, 'tooling', '*'
FROM public.plant_roles pr
WHERE pr.is_builtin
ON CONFLICT DO NOTHING;
