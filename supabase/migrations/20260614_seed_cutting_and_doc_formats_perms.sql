-- 'cutting' (Cutting Planner) and 'doc_formats' (AI-built print templates)
-- were added to the frontend menu but not the RBAC permission registry, so
-- on rbac_enforced plants (every fabrication plant) the menu filter hid
-- them. Mirror existing grants for every role that's still alive: every
-- role that has any access to 'jobwork' gets the equivalent on 'cutting';
-- every role with access to 'sales_docs' gets the equivalent on 'doc_formats'.
insert into public.role_permissions (role_id, module_key, action)
select distinct rp.role_id, 'cutting'::text, rp.action
from public.role_permissions rp
join public.plant_roles pr on pr.id = rp.role_id
where rp.module_key = 'jobwork'
on conflict do nothing;

insert into public.role_permissions (role_id, module_key, action)
select distinct rp.role_id, 'doc_formats'::text, rp.action
from public.role_permissions rp
join public.plant_roles pr on pr.id = rp.role_id
where rp.module_key = 'sales_docs'
on conflict do nothing;
