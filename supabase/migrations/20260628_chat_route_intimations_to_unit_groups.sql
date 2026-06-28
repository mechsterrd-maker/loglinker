-- Route intimations/escalations to each entity's UNIT chat group instead of the
-- single All Hands group. Applied live; recorded here for traceability.
--
-- Core: post_to_all_hands gains an optional p_unit_id. It posts to the per-unit
-- group (chat_groups where unit_ids = [that unit]); if no unit / no unit group,
-- it falls back to the type='all_hands' group (nothing is ever lost). Plant-wide
-- daily summaries keep passing NULL → All Hands.
CREATE OR REPLACE FUNCTION public.post_to_all_hands(p_plant_id uuid, p_sender_id uuid, p_body text, p_unit_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_group_id uuid; v_group_name TEXT; v_sender uuid; v_msg_id uuid;
  v_is_system BOOLEAN; v_preview TEXT;
BEGIN
  IF p_plant_id IS NULL OR p_body IS NULL OR btrim(p_body) = '' THEN RETURN NULL; END IF;
  IF p_unit_id IS NOT NULL THEN
    SELECT id, name INTO v_group_id, v_group_name FROM chat_groups
    WHERE plant_id = p_plant_id AND unit_ids = ARRAY[p_unit_id] ORDER BY created_at LIMIT 1;
  END IF;
  IF v_group_id IS NULL THEN
    SELECT id, name INTO v_group_id, v_group_name FROM chat_groups
    WHERE plant_id = p_plant_id AND type = 'all_hands' ORDER BY created_at LIMIT 1;
  END IF;
  IF v_group_id IS NULL THEN RETURN NULL; END IF;
  v_is_system := (p_sender_id IS NULL);
  v_sender := COALESCE(p_sender_id, get_system_sender(p_plant_id));
  IF v_sender IS NULL THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM chat_messages WHERE group_id = v_group_id AND body = p_body
             AND created_at > now() - interval '60 seconds') THEN RETURN NULL; END IF;
  INSERT INTO chat_messages (plant_id, group_id, sender_id, body)
  VALUES (p_plant_id, v_group_id, v_sender, p_body) RETURNING id INTO v_msg_id;
  IF v_is_system AND v_sender = ANY (SELECT unnest(members) FROM chat_groups WHERE id = v_group_id) THEN
    v_preview := COALESCE(NULLIF(LEFT(p_body, 100), ''), '📎 attachment');
    INSERT INTO notification_queue (plant_id, user_id, title, body, click_url, data, status)
    VALUES (p_plant_id, v_sender, '📋 Loglinkr in ' || COALESCE(v_group_name, 'Loglinkr'), v_preview,
      '/app?tab=chat&group=' || v_group_id::text,
      jsonb_build_object('group_id', v_group_id, 'message_id', v_msg_id, 'system', true), 'pending');
    PERFORM net.http_post(url := 'https://wzxowvrvuecybdxymjvi.supabase.co/functions/v1/send-push',
      headers := jsonb_build_object('Content-Type', 'application/json'), body := '{}'::jsonb, timeout_milliseconds := 2000);
  END IF;
  RETURN v_msg_id;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'post_to_all_hands failed: %', SQLERRM; RETURN NULL;
END $function$;

-- The 25 per-event cascade triggers (cascade_*_to_all_hands, cascade_task/action_
-- comment_to_chat, cascade_task_status_to_chat) were updated in-place to pass the
-- entity's NEW.unit_id, and post_daily_{task,ncr,breakdown,npd}_escalations to pass
-- their row's unit_id. Plant-wide summaries (task reminders, tpm, supplier runway,
-- npd pipeline, pending-by-department) intentionally keep posting to All Hands.
