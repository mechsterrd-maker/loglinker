-- Fix: plants.address/city/pincode/state are NOT NULL. The HR signup RPC didn't
-- set them → insert failed. Default them to '' for HR signups.
CREATE OR REPLACE FUNCTION public.create_hr_plant_and_signup(
  p_plant_name text,
  p_gstin text,
  p_business_type text,
  p_business_type_custom text,
  p_employee_count int,
  p_full_name text,
  p_phone text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_state text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_email text;
  v_plant_id uuid;
  v_unit_id uuid;
begin
  if v_user_id is null then return jsonb_build_object('success', false, 'error', 'Not authenticated'); end if;
  if exists (select 1 from users where id = v_user_id and plant_id is not null) then
    return jsonb_build_object('success', false, 'error', 'You already belong to a company');
  end if;
  if coalesce(btrim(p_plant_name), '') = '' then return jsonb_build_object('success', false, 'error', 'Business name is required'); end if;
  if coalesce(btrim(p_gstin), '') = '' then return jsonb_build_object('success', false, 'error', 'GSTIN is required'); end if;
  select email into v_email from auth.users where id = v_user_id;

  insert into plants (name, gstin, address, city, pincode, state, subscription_tier, business_type,
                      business_type_custom, employee_count, app_mode, approval_status,
                      subscription_status, trial_ends_at, plan_code, show_iatf_modules)
  values (btrim(p_plant_name), btrim(p_gstin), '', coalesce(p_city, ''), '', coalesce(p_state, ''),
          'lite', p_business_type, p_business_type_custom, p_employee_count, 'hr', 'approved',
          'trial', now() + interval '45 days', 'hr', false)
  returning id into v_plant_id;

  insert into units (plant_id, name) values (v_plant_id, 'Main Unit') returning id into v_unit_id;

  insert into users (id, plant_id, primary_unit_id, full_name, phone, email, role, status, active_unit_id)
  values (v_user_id, v_plant_id, v_unit_id, p_full_name, p_phone, v_email, 'plant_head', 'active', v_unit_id)
  on conflict (id) do update set
    plant_id = v_plant_id, primary_unit_id = v_unit_id, full_name = excluded.full_name,
    phone = excluded.phone, role = 'plant_head', status = 'active', active_unit_id = v_unit_id;

  insert into user_unit_access (plant_id, user_id, unit_id, role, granted_by)
  values (v_plant_id, v_user_id, v_unit_id, 'manager', v_user_id)
  on conflict (user_id, unit_id) do nothing;

  return jsonb_build_object('success', true, 'plant_id', v_plant_id, 'unit_id', v_unit_id);
exception when others then
  return jsonb_build_object('success', false, 'error', sqlerrm);
end $function$;
