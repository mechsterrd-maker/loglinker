-- Stream role-assignment + role-permission changes so a logged-in user's
-- permissions update instantly (the client refetches my_permissions on these).
-- RLS is enabled on both tables, so realtime only delivers changes the user
-- is authorized to see. Already applied to production.
ALTER PUBLICATION supabase_realtime ADD TABLE public.user_plant_roles;
ALTER PUBLICATION supabase_realtime ADD TABLE public.role_permissions;
