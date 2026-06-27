-- Invites can optionally carry a custom role. Additive + guarded: base-role
-- invites (invited_role_id NULL) behave exactly as before. redeem_invite_code
-- assigns the custom role (replacing the auto-linked base role) only when set.
-- Already applied to production. (Full function body in the matching apply_migration.)
ALTER TABLE public.user_invites ADD COLUMN IF NOT EXISTS invited_role_id uuid REFERENCES public.plant_roles(id);
