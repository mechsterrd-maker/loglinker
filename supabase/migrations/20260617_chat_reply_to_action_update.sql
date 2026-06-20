-- When someone replies in chat to a task status/comment message (which
-- carries parsed_intent.action_id), reflect that reply in the task's
-- Action Hub history AND fan it out to the other watchers' DMs.

ALTER TABLE public.action_updates
  ADD COLUMN IF NOT EXISTS source_chat_group_id   uuid REFERENCES public.chat_groups(id)   ON DELETE SET NULL;
ALTER TABLE public.action_updates
  ADD COLUMN IF NOT EXISTS source_chat_message_id uuid REFERENCES public.chat_messages(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION public.fan_action_to_dms(
  p_action_id uuid, p_actor_id uuid, p_body text, p_skip_group_id uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_action public.actions; v_dm_group uuid; v_recipients uuid[]; v_rec uuid;
BEGIN
  SELECT * INTO v_action FROM public.actions WHERE id = p_action_id;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT array_agg(DISTINCT u) FILTER (WHERE u IS NOT NULL AND u <> p_actor_id)
    INTO v_recipients
  FROM (
    SELECT v_action.assigned_by AS u
    UNION SELECT v_action.owner_id
    UNION SELECT user_id FROM public.action_watchers WHERE action_id = p_action_id
  ) s;
  IF v_recipients IS NULL THEN RETURN; END IF;
  FOREACH v_rec IN ARRAY v_recipients LOOP
    v_dm_group := public.ensure_dm_group(v_action.plant_id, p_actor_id, v_rec);
    IF v_dm_group IS NOT NULL AND (p_skip_group_id IS NULL OR v_dm_group <> p_skip_group_id) THEN
      INSERT INTO public.chat_messages (plant_id, group_id, sender_id, body, parsed_intent)
      VALUES (v_action.plant_id, v_dm_group, p_actor_id, p_body,
              jsonb_build_object('action_id', v_action.id::text, 'kind', 'task_update'));
    END IF;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.cascade_action_comment_to_chat()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_action public.actions; v_author TEXT; v_chat_body TEXT; v_preview TEXT;
BEGIN
  IF NEW.update_type <> 'comment' OR NEW.body IS NULL OR length(trim(NEW.body)) = 0 THEN
    RETURN NEW;
  END IF;
  SELECT * INTO v_action FROM public.actions WHERE id = NEW.action_id;
  IF NOT FOUND OR v_action.report_to_mode = 'self' THEN RETURN NEW; END IF;
  SELECT full_name INTO v_author FROM users WHERE id = NEW.author_id;
  v_preview := CASE WHEN length(NEW.body) > 180 THEN substr(NEW.body, 1, 180) || '…' ELSE NEW.body END;
  v_chat_body := '💬 ' || COALESCE(v_author, 'Someone') || ' on "' || v_action.title || '":'
    || E'\n' || v_preview;
  IF v_action.report_to_mode = 'group' THEN
    PERFORM post_to_all_hands(v_action.plant_id, NEW.author_id, v_chat_body);
  ELSIF v_action.report_to_mode = 'direct' THEN
    PERFORM public.fan_action_to_dms(v_action.id, NEW.author_id, v_chat_body, NEW.source_chat_group_id);
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'cascade_action_comment_to_chat: %', SQLERRM;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.cascade_chat_reply_to_action_update()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_orig_intent jsonb;
  v_action_id   uuid;
BEGIN
  IF NEW.reply_to_message_id IS NULL THEN RETURN NEW; END IF;
  IF NEW.body IS NULL OR length(trim(NEW.body)) = 0 THEN RETURN NEW; END IF;
  IF (NEW.parsed_intent->>'kind') = 'task_update' THEN RETURN NEW; END IF;
  SELECT parsed_intent INTO v_orig_intent FROM public.chat_messages WHERE id = NEW.reply_to_message_id;
  IF v_orig_intent IS NULL THEN RETURN NEW; END IF;
  v_action_id := (v_orig_intent->>'action_id')::uuid;
  IF v_action_id IS NULL THEN RETURN NEW; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.actions WHERE id = v_action_id) THEN RETURN NEW; END IF;
  INSERT INTO public.action_updates (
    plant_id, action_id, author_id, update_type, body,
    source_chat_message_id, source_chat_group_id
  ) VALUES (
    NEW.plant_id, v_action_id, NEW.sender_id, 'comment', NEW.body,
    NEW.id, NEW.group_id
  );
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'cascade_chat_reply_to_action_update: %', SQLERRM;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS chat_reply_to_action_update_trg ON public.chat_messages;
CREATE TRIGGER chat_reply_to_action_update_trg
  AFTER INSERT ON public.chat_messages
  FOR EACH ROW EXECUTE FUNCTION public.cascade_chat_reply_to_action_update();
