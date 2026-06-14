-- Profile photo URL (stored in the public chat-attachments bucket under
-- avatars/). Users edit their own profile -- the u_self_all RLS policy
-- already permits self-update.
alter table public.users add column if not exists avatar_url text;
