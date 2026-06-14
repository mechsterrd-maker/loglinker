-- Marvel: a project is sales-order-like. Add PO number, split quantity into a
-- numeric qty + a unit-of-measure field, and let the modal pass notes through.
alter table public.mcp_projects
  add column if not exists po_number text,
  add column if not exists qty numeric,
  add column if not exists uom text;

drop function if exists public.create_fab_project(text, uuid, text, text, date, uuid, uuid, uuid[]);

create or replace function public.create_fab_project(
  p_name text, p_customer_id uuid, p_customer_name text, p_qty_note text,
  p_target_date date, p_leader_id uuid, p_manager_id uuid, p_supervisor_ids uuid[],
  p_po_number text default null, p_qty numeric default null,
  p_uom text default null, p_notes text default null
) returns uuid language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid(); v_plant uuid; v_role text; v_proj uuid; s_id uuid; v_notes text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select plant_id, role::text into v_plant, v_role from public.users where id = v_uid;
  if v_plant is null then raise exception 'caller_has_no_plant'; end if;
  if v_role not in ('plant_head','admin') then raise exception 'forbidden: plant_head/admin only'; end if;
  if p_name is null or length(trim(p_name)) < 2 then raise exception 'name_required'; end if;
  v_notes := nullif(trim(coalesce(p_notes, '')), '');
  if v_notes is null and p_qty_note is not null and length(trim(p_qty_note)) > 0 then
    v_notes := 'Qty: ' || trim(p_qty_note);
  end if;
  insert into public.mcp_projects (
    plant_id, name, customer_id, customer_name, target_date,
    owner_user_id, notes, po_number, qty, uom, status, created_by
  ) values (
    v_plant, trim(p_name), p_customer_id, p_customer_name, p_target_date,
    coalesce(p_leader_id, v_uid), v_notes,
    nullif(trim(coalesce(p_po_number, '')), ''), p_qty,
    nullif(trim(coalesce(p_uom, '')), ''), 'planning', v_uid
  ) returning id into v_proj;
  if p_leader_id is not null then
    insert into public.mcp_project_members (project_id, user_id, role_label, added_by)
    values (v_proj, p_leader_id, 'leader', v_uid) on conflict do nothing;
  end if;
  if p_manager_id is not null and p_manager_id <> coalesce(p_leader_id, '00000000-0000-0000-0000-000000000000'::uuid) then
    insert into public.mcp_project_members (project_id, user_id, role_label, added_by)
    values (v_proj, p_manager_id, 'manager', v_uid) on conflict do nothing;
  end if;
  if p_supervisor_ids is not null then
    foreach s_id in array p_supervisor_ids loop
      insert into public.mcp_project_members (project_id, user_id, role_label, added_by)
      values (v_proj, s_id, 'supervisor', v_uid) on conflict do nothing;
    end loop;
  end if;
  return v_proj;
end;
$function$;
