-- Move a consumption line's cost to a different project (fix a wrong tag) without
-- disturbing the stock movement or the source document.
create or replace function public.retag_project_material_usage(p_usage_id uuid, p_new_project_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_u public.mcp_project_material_usage%rowtype; v_plant uuid := public.my_plant_id();
begin
  select * into v_u from public.mcp_project_material_usage where id = p_usage_id;
  if v_u.id is null or v_u.plant_id is distinct from v_plant then return jsonb_build_object('success', false, 'error', 'No access'); end if;
  if not exists (select 1 from public.mcp_projects where id = p_new_project_id and plant_id = v_plant) then return jsonb_build_object('success', false, 'error', 'No access to that project'); end if;
  update public.mcp_project_material_usage set project_id = p_new_project_id where id = p_usage_id;
  return jsonb_build_object('success', true);
exception when others then return jsonb_build_object('success', false, 'error', sqlerrm); end $$;
grant execute on function public.retag_project_material_usage(uuid, uuid) to authenticated;
