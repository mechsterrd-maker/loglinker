-- Three visibility modes for tasks:
--   'group'  — existing behaviour: post to All Hands on create / status / comment.
--   'self'   — silent: no chat broadcast at all.
--   'direct' — fan out to assigner + owner + watchers via 1:1 DM groups.

-- ---------------------------------------------------------------------------
-- 1. report_to_mode column on actions
-- ---------------------------------------------------------------------------
ALTER TABLE public.actions
  ADD COLUMN IF NOT EXISTS report_to_mode text NOT NULL DEFAULT 'group';
ALTER TABLE public.actions
  DROP CONSTRAINT IF EXISTS actions_report_to_mode_check;
ALTER TABLE public.actions
  ADD CONSTRAINT actions_report_to_mode_check
  CHECK (report_to_mode IN ('group', 'direct', 'self'));

-- ---------------------------------------------------------------------------
-- 2. Watchers (people CC'd on 'direct' tasks)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.action_watchers (
  action_id uuid NOT NULL REFERENCES public.actions(id) ON DELETE CASCADE,
  user_id   uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  plant_id  uuid NOT NULL,
  added_at  timestamptz NOT NULL DEFAULT now(),
  added_by  uuid REFERENCES public.users(id),
  PRIMARY KEY (action_id, user_id)
);
CREATE INDEX IF NOT EXISTS action_watchers_user_idx   ON public.action_watchers (user_id, plant_id);
CREATE INDEX IF NOT EXISTS action_watchers_action_idx ON public.action_watchers (action_id);

ALTER TABLE public.action_watchers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS action_watchers_select ON public.action_watchers;
CREATE POLICY action_watchers_select ON public.action_watchers FOR SELECT
  USING (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()));
DROP POLICY IF EXISTS action_watchers_modify ON public.action_watchers;
CREATE POLICY action_watchers_modify ON public.action_watchers FOR ALL
  USING (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()))
  WITH CHECK (auth.uid() IS NOT NULL AND plant_id IN (SELECT u.plant_id FROM users u WHERE u.id = auth.uid()));

-- ---------------------------------------------------------------------------
-- 3. ensure_dm_group — find or create the 1:1 chat group between two users
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_dm_group(
  p_plant_id uuid, p_user_a uuid, p_user_b uuid
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id uuid; v_name text;
BEGIN
  IF p_user_a IS NULL OR p_user_b IS NULL OR p_user_a = p_user_b THEN RETURN NULL; END IF;
  v_name := 'DM:' || LEAST(p_user_a::text, p_user_b::text) || ':' || GREATEST(p_user_a::text, p_user_b::text);
  SELECT id INTO v_id FROM public.chat_groups WHERE plant_id = p_plant_id AND name = v_name LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  INSERT INTO public.chat_groups (plant_id, name, type, members, created_by)
  VALUES (p_plant_id, v_name, 'custom', ARRAY[p_user_a, p_user_b], p_user_a)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- 4. fan_action_to_dms — drop a message in each recipient's DM with actor
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_action_to_dms(
  p_action_id uuid, p_actor_id uuid, p_body text
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
    IF v_dm_group IS NOT NULL THEN
      INSERT INTO public.chat_messages (plant_id, group_id, sender_id, body, parsed_intent)
      VALUES (v_action.plant_id, v_dm_group, p_actor_id, p_body,
              jsonb_build_object('action_id', v_action.id::text, 'kind', 'task_update'));
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 5. Replace cascade_action_created_to_all_hands to respect report_to_mode
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cascade_action_created_to_all_hands()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_owner TEXT; v_assigner TEXT; v_due TEXT; v_body TEXT;
BEGIN
  IF NEW.report_to_mode = 'self' THEN RETURN NEW; END IF;
  SELECT full_name INTO v_owner    FROM users WHERE id = NEW.owner_id;
  SELECT full_name INTO v_assigner FROM users WHERE id = NEW.assigned_by;
  v_due := CASE
    WHEN NEW.due_at IS NULL THEN 'no due date'
    WHEN NEW.due_at::date = CURRENT_DATE THEN 'due today'
    WHEN NEW.due_at::date = CURRENT_DATE + 1 THEN 'due tomorrow'
    ELSE 'due ' || to_char(NEW.due_at, 'DD Mon')
  END;
  v_body := '🆕 New task: "' || NEW.title || '"'
    || CASE WHEN v_owner IS NOT NULL THEN E'\n→ assigned to ' || v_owner ELSE '' END
    || CASE WHEN v_assigner IS NOT NULL AND v_assigner != COALESCE(v_owner,'') THEN ' by ' || v_assigner ELSE '' END
    || ' · ' || v_due
    || CASE WHEN NEW.source_label IS NOT NULL THEN E'\n↳ ' || NEW.source_label ELSE '' END;
  IF NEW.report_to_mode = 'group' THEN
    PERFORM post_to_all_hands(NEW.plant_id, NEW.assigned_by, v_body);
  END IF;
  -- 'direct' is deferred to broadcast_action_create RPC (client calls after
  -- inserting watchers, since they're not visible to this trigger yet).
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'cascade_action_created_to_all_hands: %', SQLERRM;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------------
-- 6. Replace cascade_task_status_to_chat to respect report_to_mode
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cascade_task_status_to_chat()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_actor_name TEXT; v_chat_body TEXT; v_status_label TEXT; v_emoji TEXT; v_actor_id uuid;
BEGIN
  IF OLD.status = NEW.status THEN RETURN NEW; END IF;
  IF NEW.report_to_mode = 'self' THEN RETURN NEW; END IF;
  CASE NEW.status
    WHEN 'in_progress' THEN v_emoji := '▶️'; v_status_label := 'Started working on';
    WHEN 'completed'   THEN v_emoji := '✅'; v_status_label := 'Closed';
    WHEN 'cancelled'   THEN v_emoji := '❌'; v_status_label := 'Cancelled';
    WHEN 'open'        THEN v_emoji := '🔓'; v_status_label := 'Reopened';
    ELSE v_emoji := '·'; v_status_label := 'Updated to ' || NEW.status;
  END CASE;
  v_actor_id := COALESCE(auth.uid(), NEW.owner_id);
  SELECT full_name INTO v_actor_name FROM users WHERE id = v_actor_id;
  v_chat_body := v_emoji || ' ' || v_status_label || ' task "' || NEW.title || '"'
    || CASE WHEN v_actor_name IS NOT NULL THEN ' — ' || v_actor_name ELSE '' END;
  IF NEW.report_to_mode = 'group' THEN
    IF NEW.chat_group_id IS NOT NULL THEN
      INSERT INTO chat_messages (plant_id, group_id, sender_id, body)
      VALUES (NEW.plant_id, NEW.chat_group_id, v_actor_id, v_chat_body);
    END IF;
    PERFORM post_to_all_hands(NEW.plant_id, v_actor_id, v_chat_body);
  ELSIF NEW.report_to_mode = 'direct' THEN
    PERFORM public.fan_action_to_dms(NEW.id, v_actor_id, v_chat_body);
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'cascade_task_status_to_chat: %', SQLERRM;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------------
-- 7. NEW: broadcast user comments (action_updates) by mode
-- ---------------------------------------------------------------------------
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
  v_chat_body := '💬 ' || COALESCE(v_author, 'Someone') || ' commented on "' || v_action.title || '":'
    || E'\n' || v_preview;
  IF v_action.report_to_mode = 'group' THEN
    PERFORM post_to_all_hands(v_action.plant_id, NEW.author_id, v_chat_body);
  ELSIF v_action.report_to_mode = 'direct' THEN
    PERFORM public.fan_action_to_dms(v_action.id, NEW.author_id, v_chat_body);
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'cascade_action_comment_to_chat: %', SQLERRM;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS action_comment_to_chat_trg ON public.action_updates;
CREATE TRIGGER action_comment_to_chat_trg
  AFTER INSERT ON public.action_updates
  FOR EACH ROW EXECUTE FUNCTION public.cascade_action_comment_to_chat();

-- ---------------------------------------------------------------------------
-- 8. broadcast_action_create — client RPC called after inserting watchers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.broadcast_action_create(p_action_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_action public.actions; v_owner TEXT; v_assigner TEXT; v_due TEXT; v_body TEXT;
BEGIN
  SELECT * INTO v_action FROM public.actions WHERE id = p_action_id;
  IF NOT FOUND OR v_action.report_to_mode <> 'direct' THEN RETURN; END IF;
  SELECT full_name INTO v_owner    FROM users WHERE id = v_action.owner_id;
  SELECT full_name INTO v_assigner FROM users WHERE id = v_action.assigned_by;
  v_due := CASE
    WHEN v_action.due_at IS NULL THEN 'no due date'
    WHEN v_action.due_at::date = CURRENT_DATE THEN 'due today'
    WHEN v_action.due_at::date = CURRENT_DATE + 1 THEN 'due tomorrow'
    ELSE 'due ' || to_char(v_action.due_at, 'DD Mon')
  END;
  v_body := '🆕 New task: "' || v_action.title || '"'
    || CASE WHEN v_owner IS NOT NULL THEN E'\n→ assigned to ' || v_owner ELSE '' END
    || CASE WHEN v_assigner IS NOT NULL AND v_assigner != COALESCE(v_owner,'') THEN ' by ' || v_assigner ELSE '' END
    || ' · ' || v_due;
  PERFORM public.fan_action_to_dms(v_action.id, COALESCE(auth.uid(), v_action.assigned_by), v_body);
END $$;
