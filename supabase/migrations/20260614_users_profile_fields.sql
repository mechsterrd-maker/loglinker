-- Extra self-editable profile fields. Designation/department are display
-- labels separate from the system role; emergency info is common in Indian
-- factory HR records. Self-update covered by the existing u_self_all policy.
alter table public.users
  add column if not exists designation text,
  add column if not exists department text,
  add column if not exists blood_group text,
  add column if not exists emergency_contact_name text,
  add column if not exists emergency_contact_phone text;
