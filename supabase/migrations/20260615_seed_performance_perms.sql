-- Performance Dashboards module: clone every still-alive reports grant onto
-- performance so the same audience can see it.
insert into public.role_permissions (role_id, module_key, action)
select distinct rp.role_id, 'performance'::text, rp.action
from public.role_permissions rp
join public.plant_roles pr on pr.id = rp.role_id
where rp.module_key = 'reports'
on conflict do nothing;
