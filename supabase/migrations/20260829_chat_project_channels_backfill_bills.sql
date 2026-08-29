-- One-time backfill: the per-project channels (Phase 3A) were created empty, so
-- the 🧾 bill count (derived from mcp_logistics_documents.project_id) showed a
-- number but the channel had no messages. Post each project-tagged document into
-- its project channel as a dated message so the past bills are visible. Idempotent
-- via parsed_intent->>'backfill_doc_id'. Marvel only. Applied via MCP; tracked mirror.
insert into public.chat_messages (plant_id, group_id, sender_id, body, attachments, created_at, parsed_intent)
select d.plant_id, g.id, d.created_by,
  '🧾 ' || replace(coalesce(d.doc_type::text, 'document'), '_', ' ')
    || ' · ' || coalesce(nullif(btrim(d.vendor_name_raw), ''), '—')
    || coalesce(' · ' || d.doc_number, '')
    || coalesce(' · ₹' || trim(to_char(d.total_value, 'FM999999990')), ''),
  case when d.source_image_url is not null then jsonb_build_array(jsonb_build_object(
        'url', d.source_image_url,
        'name', coalesce(d.doc_number, 'bill'),
        'isImage', d.source_image_url ~* '\.(jpg|jpeg|png|webp|gif|heic)(\?|$)',
        'isPdf', d.source_image_url ~* '\.pdf(\?|$)'))
       else null end,
  d.created_at,
  jsonb_build_object('backfill_doc_id', d.id::text, 'doc_id', d.id::text)
from public.mcp_logistics_documents d
join public.chat_groups g
  on g.plant_id = d.plant_id and (g.metadata->>'project_id')::uuid = d.project_id
where d.plant_id = 'b1f10825-75e0-4a83-8de8-8941f47e5928'
  and d.project_id is not null
  and d.created_by is not null
  and not exists (
    select 1 from public.chat_messages m
    where m.group_id = g.id and m.parsed_intent->>'backfill_doc_id' = d.id::text
  );
