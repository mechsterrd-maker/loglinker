-- WhatsApp message interactions: reply, reactions, star, delete-for-me, pin,
-- @mentions. Per-user state lives on the message row; cross-user mutations go
-- through SECURITY DEFINER RPCs.
alter table public.chat_messages
  add column if not exists reply_to_message_id uuid references public.chat_messages(id) on delete set null,
  add column if not exists reactions jsonb not null default '{}'::jsonb,
  add column if not exists starred_by uuid[] not null default '{}'::uuid[],
  add column if not exists deleted_for uuid[] not null default '{}'::uuid[],
  add column if not exists mentions uuid[] not null default '{}'::uuid[],
  add column if not exists pinned_at timestamptz,
  add column if not exists pinned_by uuid;

create or replace function public.can_touch_message(p_msg chat_messages, p_uid uuid)
returns boolean language plpgsql stable security definer as $$
declare v_ok boolean;
begin
  select (p_uid = any(g.members))
      or exists (select 1 from users u where u.id = p_uid and u.plant_id = g.plant_id and u.role in ('plant_head','admin'))
    into v_ok from chat_groups g where g.id = p_msg.group_id;
  return coalesce(v_ok, false);
end $$;

create or replace function public.toggle_message_reaction(p_message_id uuid, p_emoji text)
returns jsonb language plpgsql security definer as $function$
declare v_uid uuid := auth.uid(); v_msg chat_messages; v_arr jsonb; v_have boolean;
begin
  select * into v_msg from chat_messages where id = p_message_id;
  if v_msg.id is null then return jsonb_build_object('success', false, 'error', 'Message not found'); end if;
  if not public.can_touch_message(v_msg, v_uid) then return jsonb_build_object('success', false, 'error', 'Not allowed'); end if;
  v_arr := coalesce(v_msg.reactions -> p_emoji, '[]'::jsonb);
  v_have := v_arr ? v_uid::text;
  if v_have then
    v_arr := (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements_text(v_arr) x where x <> v_uid::text);
  else
    v_arr := v_arr || to_jsonb(v_uid::text);
  end if;
  if jsonb_array_length(v_arr) = 0 then
    update chat_messages set reactions = reactions - p_emoji where id = p_message_id;
  else
    update chat_messages set reactions = jsonb_set(reactions, array[p_emoji], v_arr, true) where id = p_message_id;
  end if;
  return jsonb_build_object('success', true);
end $function$;

create or replace function public.toggle_star_message(p_message_id uuid)
returns jsonb language plpgsql security definer as $function$
declare v_uid uuid := auth.uid(); v_msg chat_messages;
begin
  select * into v_msg from chat_messages where id = p_message_id;
  if v_msg.id is null then return jsonb_build_object('success', false, 'error', 'Message not found'); end if;
  if not public.can_touch_message(v_msg, v_uid) then return jsonb_build_object('success', false, 'error', 'Not allowed'); end if;
  if v_uid = any(coalesce(v_msg.starred_by,'{}'::uuid[])) then
    update chat_messages set starred_by = array_remove(starred_by, v_uid) where id = p_message_id;
  else
    update chat_messages set starred_by = array_append(coalesce(starred_by,'{}'::uuid[]), v_uid) where id = p_message_id;
  end if;
  return jsonb_build_object('success', true);
end $function$;

create or replace function public.delete_message_for_me(p_message_id uuid)
returns jsonb language plpgsql security definer as $function$
declare v_uid uuid := auth.uid(); v_msg chat_messages;
begin
  select * into v_msg from chat_messages where id = p_message_id;
  if v_msg.id is null then return jsonb_build_object('success', false, 'error', 'Message not found'); end if;
  if not public.can_touch_message(v_msg, v_uid) then return jsonb_build_object('success', false, 'error', 'Not allowed'); end if;
  update chat_messages set deleted_for = array_append(coalesce(deleted_for,'{}'::uuid[]), v_uid)
   where id = p_message_id and not (v_uid = any(coalesce(deleted_for,'{}'::uuid[])));
  return jsonb_build_object('success', true);
end $function$;

create or replace function public.set_message_pin(p_message_id uuid, p_pinned boolean)
returns jsonb language plpgsql security definer as $function$
declare v_uid uuid := auth.uid(); v_msg chat_messages;
begin
  select * into v_msg from chat_messages where id = p_message_id;
  if v_msg.id is null then return jsonb_build_object('success', false, 'error', 'Message not found'); end if;
  if not public.can_touch_message(v_msg, v_uid) then return jsonb_build_object('success', false, 'error', 'Not allowed'); end if;
  if p_pinned then
    update chat_messages set pinned_at = now(), pinned_by = v_uid where id = p_message_id;
  else
    update chat_messages set pinned_at = null, pinned_by = null where id = p_message_id;
  end if;
  return jsonb_build_object('success', true);
end $function$;
