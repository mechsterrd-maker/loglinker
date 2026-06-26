-- RBAC enforcement for Starter Pack plants + workforce modules in the matrix.
--
-- 1. Add the workforce/attendance + quotation modules to the builtin-role seed
--    so plant_head/admin get '*' on them and manager/supervisor/operator get
--    sensible defaults. Without this, those tabs were invisible in the role
--    matrix and an enforced plant couldn't grant them.
-- 2. Make starter plants RBAC-enforced by default (trigger) and flip the two
--    existing starter plants on.
-- 3. Re-seed the existing starter plants (idempotent: ON CONFLICT DO NOTHING
--    only ADDS the new module perms, never removes custom grants).

CREATE OR REPLACE FUNCTION public.seed_builtin_roles_for_plant(p_plant_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role_id uuid;
  -- All module keys we currently know about, kept here so the seed is grep-able.
  -- Source: MORE_GROUPS + RBAC_MODULES in app.html. Keep in sync as modules change.
  v_modules text[] := array[
    'home','production','quality','maintenance','stocks','actions','documents',
    'schedules','movements','trace','reports','chat','people','masters',
    'iatf','calibration','training','ppap','pfmea','lpa','mgmt_review','csr','scl',
    'iap','pm_schedule','quality_objectives','risk_register','contingency',
    'npd','tpm','rejection_types','iatf_docs','mom','customer_complaints',
    'jobwork','machine_prod','supplier_chase','petty_cash','sales_docs',
    'expenses','projects','cad3d',
    -- workforce / attendance / payroll + costing
    'self_attendance','attendance','attendance_setup','quotation'
  ];
begin
  -- Plant Head: '*' on every module
  insert into public.plant_roles (plant_id, slug, display_name, description, is_builtin, sort_order)
  values (p_plant_id, 'plant_head', 'Plant Head', 'Full access to everything in the plant. Cannot be deleted.', true, 10)
  on conflict (plant_id, slug) do nothing
  returning id into v_role_id;
  if v_role_id is null then
    select id into v_role_id from public.plant_roles where plant_id = p_plant_id and slug = 'plant_head';
  end if;
  insert into public.role_permissions (role_id, module_key, action)
    select v_role_id, m_, '*' from unnest(v_modules) m_
    on conflict do nothing;

  -- Admin: '*' on every module
  insert into public.plant_roles (plant_id, slug, display_name, description, is_builtin, sort_order)
  values (p_plant_id, 'admin', 'Admin', 'Full operational access. Can manage users and plant settings.', true, 20)
  on conflict (plant_id, slug) do nothing
  returning id into v_role_id;
  if v_role_id is null then
    select id into v_role_id from public.plant_roles where plant_id = p_plant_id and slug = 'admin';
  end if;
  insert into public.role_permissions (role_id, module_key, action)
    select v_role_id, m_, '*' from unnest(v_modules) m_
    on conflict do nothing;

  -- Manager: view+create+edit on operational modules incl. the full workforce surface
  insert into public.plant_roles (plant_id, slug, display_name, description, is_builtin, sort_order)
  values (p_plant_id, 'manager', 'Manager', 'Unit-level operational access. Stocks, schedules, projects, billing, workforce.', true, 30)
  on conflict (plant_id, slug) do nothing
  returning id into v_role_id;
  if v_role_id is null then
    select id into v_role_id from public.plant_roles where plant_id = p_plant_id and slug = 'manager';
  end if;
  insert into public.role_permissions (role_id, module_key, action)
    select v_role_id, m_, '*' from unnest(array[
      'home','production','quality','maintenance','stocks','actions','documents',
      'schedules','movements','trace','reports','chat','people','masters',
      'projects','cad3d','sales_docs','expenses','jobwork','npd','mom',
      'customer_complaints','tpm','supplier_chase','petty_cash','machine_prod',
      'self_attendance','attendance','attendance_setup','quotation'
    ]) m_
    on conflict do nothing;

  -- Supervisor: floor + verify, plus marking the attendance register.
  insert into public.plant_roles (plant_id, slug, display_name, description, is_builtin, sort_order)
  values (p_plant_id, 'supervisor', 'Supervisor', 'Shift / floor lead. Logs production, verifies entries, marks attendance, raises NCRs.', true, 40)
  on conflict (plant_id, slug) do nothing
  returning id into v_role_id;
  if v_role_id is null then
    select id into v_role_id from public.plant_roles where plant_id = p_plant_id and slug = 'supervisor';
  end if;
  -- view on everything operational + own punch + attendance register
  insert into public.role_permissions (role_id, module_key, action)
    select v_role_id, m_, 'view' from unnest(array[
      'home','production','quality','maintenance','stocks','actions','documents',
      'schedules','movements','trace','reports','chat','people','masters',
      'projects','cad3d','jobwork','tpm','customer_complaints','machine_prod','supplier_chase',
      'self_attendance','attendance'
    ]) m_
    on conflict do nothing;
  -- create/edit on the floor work + attendance marking
  insert into public.role_permissions (role_id, module_key, action)
    select v_role_id, m_, a_ from
      unnest(array['production','quality','maintenance','stocks','actions','tpm','chat','documents','projects','self_attendance','attendance']) m_,
      unnest(array['create','edit']) a_
    on conflict do nothing;

  -- Operator: shop-floor staff. By default can punch their own attendance so a
  -- freshly added employee isn't stranded; everything else stays denied until
  -- an admin grants it in the matrix.
  insert into public.plant_roles (plant_id, slug, display_name, description, is_builtin, sort_order)
  values (p_plant_id, 'operator', 'Operator', 'Shop-floor operator. Can punch their own attendance. No other app access by default.', true, 50)
  on conflict (plant_id, slug) do nothing
  returning id into v_role_id;
  if v_role_id is null then
    select id into v_role_id from public.plant_roles where plant_id = p_plant_id and slug = 'operator';
  end if;
  insert into public.role_permissions (role_id, module_key, action)
    select v_role_id, 'self_attendance', a_ from unnest(array['view','create']) a_
    on conflict do nothing;
end;
$function$;

-- Starter plants are RBAC-enforced by default from now on.
CREATE OR REPLACE FUNCTION public.plants_apply_business_type_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.business_type = 'starter' THEN
    IF NEW.enabled_tabs IS NULL THEN
      NEW.enabled_tabs := ARRAY['self_attendance', 'attendance', 'attendance_setup', 'petty_cash', 'actions'];
    END IF;
    IF NEW.quick_entry_tiles IS NULL THEN
      NEW.quick_entry_tiles := ARRAY['self_attendance', 'petty_cash', 'actions'];
    END IF;
    -- Enforce the role matrix for Starter Pack plants so the owner's access
    -- grants actually block ungranted modules. Owners (plant_head/admin) and
    -- zero-permission users are never locked out (see moduleAccessGuard).
    NEW.rbac_enforced := true;
    IF COALESCE(NEW.approval_status, 'pending') = 'pending' THEN
      NEW.approval_status := 'approved';
      IF NEW.approval_decided_at IS NULL THEN
        NEW.approval_decided_at := now();
      END IF;
      IF NEW.approval_note IS NULL THEN
        NEW.approval_note := 'Auto-approved · Starter Pack (no payment gate)';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $function$;

-- Re-seed + enforce the two existing starter plants.
SELECT public.seed_builtin_roles_for_plant(id) FROM public.plants WHERE business_type = 'starter';
UPDATE public.plants SET rbac_enforced = true WHERE business_type = 'starter';
