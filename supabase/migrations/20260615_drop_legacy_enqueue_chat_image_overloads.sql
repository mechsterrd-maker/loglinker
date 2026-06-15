-- Three overloads of enqueue_chat_image_for_extraction (3-arg, 4-arg, 5-arg)
-- caused PostgREST to fail with "Could not choose the best candidate function"
-- when the legacy chat path called it with just 3 named args. The 5-arg
-- signature already has DEFAULT NULL for p_project_id and p_stage_id, so the
-- older overloads are pure redundancy. Drop them and let the 5-arg version
-- handle every call shape.
drop function if exists public.enqueue_chat_image_for_extraction(uuid, uuid, text);
drop function if exists public.enqueue_chat_image_for_extraction(uuid, uuid, text, uuid);
