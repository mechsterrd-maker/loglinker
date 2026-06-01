-- Fix for production-applied migration `password_reset_tokens_fix_pgcrypto_path`.
-- `gen_random_bytes` lives in the `extensions` schema on Supabase, but
-- the SECURITY DEFINER `issue_password_reset` was created with
-- search_path = public — so the call failed at runtime with
-- "function gen_random_bytes(integer) does not exist".
--
-- This file mirrors what was applied via the dashboard so the repo stays
-- in sync; safely idempotent via CREATE OR REPLACE.

create or replace function public.issue_password_reset(p_target_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_caller uuid := auth.uid();
  v_caller_role text;
  v_caller_plant uuid;
  v_target_plant uuid;
  v_target_email text;
  v_token text;
  v_expires timestamptz;
begin
  if v_caller is null then raise exception 'not_authenticated'; end if;
  select role::text, plant_id into v_caller_role, v_caller_plant from public.users where id = v_caller;
  if v_caller_role is null then raise exception 'caller_not_found'; end if;
  if v_caller_role not in ('plant_head','admin','manager') then
    raise exception 'forbidden: only plant_head/admin/manager can issue resets';
  end if;
  select plant_id, email into v_target_plant, v_target_email from public.users where id = p_target_user_id;
  if v_target_plant is null then raise exception 'target_not_found'; end if;
  if v_target_plant <> v_caller_plant then
    raise exception 'forbidden: target user is in a different plant';
  end if;
  v_token := translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/=', '-_');
  v_expires := now() + interval '24 hours';
  update public.users
     set reset_token = v_token,
         reset_token_expires_at = v_expires,
         reset_token_issued_at = now(),
         reset_token_issued_by = v_caller
   where id = p_target_user_id;
  return jsonb_build_object('token', v_token, 'expires_at', v_expires, 'email', v_target_email);
end;
$$;
