-- OCR a bill uploaded outside chat (the "Upload Bill" button → Documents processor).
-- Mirrors enqueue_chat_image_for_extraction but with no chat message/group.
create or replace function public.enqueue_bill_for_extraction(p_plant_id uuid, p_unit_id uuid, p_image_url text)
returns uuid language plpgsql security definer set search_path=public as $fn$
declare v_uid uuid := auth.uid(); v_plant uuid; v_id uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select plant_id into v_plant from public.users where id = v_uid;
  if v_plant is null or v_plant <> p_plant_id then raise exception 'forbidden'; end if;
  if p_image_url is null or btrim(p_image_url) = '' then raise exception 'image_url required'; end if;
  insert into public.mcp_logistics_extraction_queue (plant_id, unit_id, message_id, group_id, image_url, status)
  values (p_plant_id, p_unit_id, null, null, p_image_url, 'pending')
  returning id into v_id;
  return v_id;
end $fn$;
grant execute on function public.enqueue_bill_for_extraction(uuid, uuid, text) to authenticated;
