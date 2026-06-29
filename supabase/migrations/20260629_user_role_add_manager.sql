-- Assigning the built-in "plant incharge" role (slug 'manager') failed with
-- 'invalid input value for enum user_role: "manager"'. assign_user_roles syncs
-- the legacy base role (users.role) to the assigned built-in's slug, and the
-- app already treats 'manager' as a base role (e.g. manage/broadcast checks),
-- but the enum never had the value. Add it.
ALTER TYPE public.user_role ADD VALUE IF NOT EXISTS 'manager';
