-- Voice Notes module: clone every still-alive mom grant onto voice_notes so
-- the people who run MoM also see the new audio upload page.
insert into public.role_permissions (role_id, module_key, action)
select distinct rp.role_id, 'voice_notes'::text, rp.action
from public.role_permissions rp
join public.plant_roles pr on pr.id = rp.role_id
where rp.module_key = 'mom'
on conflict do nothing;
