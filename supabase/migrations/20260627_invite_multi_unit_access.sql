-- Multi-unit access defined at invite time. The invite can now carry a set of
-- units (unit_ids) the employee should be able to access, in addition to the
-- single primary_unit_id. On redeem we grant access to each (the auto-grant
-- trigger only covers the primary unit for non-admins).
ALTER TABLE public.user_invites
  ADD COLUMN IF NOT EXISTS unit_ids uuid[];

CREATE OR REPLACE FUNCTION public.redeem_invite_code(p_code text, p_full_name text, p_phone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_user_id UUID;
  v_email TEXT;
  v_invite RECORD;
  v_existing UUID;
  v_cap INT;
  v_seats INT;
  v_unit_role unit_role;
BEGIN
  v_user_id = auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  SELECT email INTO v_email FROM auth.users WHERE id = v_user_id;

  SELECT id INTO v_existing FROM users WHERE id = v_user_id;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'You already have an account in a plant');
  END IF;

  SELECT * INTO v_invite FROM user_invites
  WHERE invite_code = UPPER(p_code) AND status = 'pending'
  LIMIT 1;

  IF v_invite IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid or already-used invite code');
  END IF;

  SELECT max_users INTO v_cap FROM plants WHERE id = v_invite.plant_id;
  IF v_cap IS NOT NULL THEN
    SELECT count(*) INTO v_seats FROM users
      WHERE plant_id = v_invite.plant_id AND status = 'active'
        AND coalesce(login_enabled, true) = true;
    IF v_seats >= v_cap THEN
      RETURN jsonb_build_object('success', false, 'error',
        'User limit reached (' || v_cap || ' seats). Ask the plant owner to upgrade the plan before adding more users.');
    END IF;
  END IF;

  INSERT INTO users (id, plant_id, primary_unit_id, full_name, phone, email, role, status)
  VALUES (v_user_id, v_invite.plant_id, v_invite.primary_unit_id, p_full_name, p_phone, v_email, v_invite.role, 'active');

  UPDATE user_invites SET status = 'accepted', accepted_at = now(), accepted_by_user_id = v_user_id WHERE id = v_invite.id;

  UPDATE chat_groups SET members = array_append(members, v_user_id)
  WHERE plant_id = v_invite.plant_id AND type = 'all_hands' AND NOT (v_user_id = ANY(members));

  -- If the invite carried a custom role, make it the member's role.
  IF v_invite.invited_role_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM plant_roles WHERE id = v_invite.invited_role_id AND plant_id = v_invite.plant_id) THEN
    DELETE FROM user_plant_roles WHERE user_id = v_user_id;
    INSERT INTO user_plant_roles (user_id, role_id) VALUES (v_user_id, v_invite.invited_role_id) ON CONFLICT DO NOTHING;
  END IF;

  -- Grant access to any ADDITIONAL units chosen at invite time. The auto-grant
  -- trigger already covers the primary unit (and all units for admins); this
  -- adds the extra units a multi-unit employee was assigned.
  IF v_invite.unit_ids IS NOT NULL AND array_length(v_invite.unit_ids, 1) > 0 THEN
    v_unit_role := CASE
      WHEN v_invite.role IN ('plant_head','admin') THEN 'manager'::unit_role
      WHEN v_invite.role = 'supervisor' THEN 'supervisor'::unit_role
      ELSE 'operator'::unit_role
    END;
    INSERT INTO user_unit_access (plant_id, user_id, unit_id, role, granted_by)
    SELECT v_invite.plant_id, v_user_id, uid, v_unit_role, v_user_id
    FROM unnest(v_invite.unit_ids) AS uid
    WHERE uid IN (SELECT id FROM units WHERE plant_id = v_invite.plant_id)
    ON CONFLICT (user_id, unit_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object('success', true, 'plant_id', v_invite.plant_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END $function$;
