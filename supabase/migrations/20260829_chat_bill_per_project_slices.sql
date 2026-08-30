-- Multi-project bills: a document's line items can each belong to a different
-- project (per-item project_id, assigned after extraction). Posting the WHOLE
-- bill (with its full total) into one project channel showed unrelated projects'
-- value. Instead post a PER-PROJECT SLICE into each project's channel — only that
-- project's items and that project's subtotal. Effective project per item =
-- item.project_id, falling back to the document's project_id (so single-project
-- and doc-level-tagged bills still route). Auto-syncs via an items-change trigger;
-- exceptions are swallowed so a sync failure can never block a document save.
-- Replaces the earlier whole-bill backfill (20260829_..._backfill_bills). Marvel
-- only (chat_lanes_enabled). Applied via MCP; tracked mirror.

create or replace function public._sync_bill_project_channels(p_doc_id uuid)
returns void language plpgsql security definer set search_path=public as $fn$
declare d record; pid text; grp uuid;
begin
  select * into d from public.mcp_logistics_documents where id = p_doc_id;
  if d.id is null then return; end if;
  if not coalesce((select chat_lanes_enabled from public.plants where id = d.plant_id), false) then return; end if;

  delete from public.chat_messages
    where (parsed_intent->>'doc_slice_id' = p_doc_id::text)
       or (parsed_intent->>'backfill_doc_id' = p_doc_id::text);

  for pid in
    select distinct coalesce(nullif(it->>'project_id',''), d.project_id::text) as eff
    from jsonb_array_elements(coalesce(d.items, '[]'::jsonb)) it
    where coalesce(nullif(it->>'project_id',''), d.project_id::text) is not null
  loop
    select id into grp from public.chat_groups
      where plant_id = d.plant_id and metadata->>'project_id' = pid limit 1;
    if grp is null then continue; end if;

    insert into public.chat_messages (plant_id, group_id, sender_id, body, attachments, created_at, parsed_intent)
    select d.plant_id, grp, d.created_by,
      '🧾 ' || replace(coalesce(d.doc_type::text,'document'),'_',' ')
        || ' · ' || coalesce(nullif(btrim(d.vendor_name_raw),''),'—')
        || coalesce(' · ' || d.doc_number, '')
        || E'\n' || string_agg(
             '• ' || coalesce(nullif(btrim(x.nm),''),'item')
               || case when x.qty is not null then ' × ' || trim(to_char(x.qty,'FM999999990.###')) || ' ' || coalesce(x.uom,'nos') else '' end
               || case when x.amt is not null then '  ₹' || trim(to_char(x.amt,'FM99,99,99,990.00')) else '' end,
             E'\n' order by x.ord)
        || case when sum(coalesce(x.amt,0)) > 0
                then E'\n— This project: ₹' || trim(to_char(sum(x.amt),'FM99,99,99,990.00'))
                else '' end,
      case when d.source_image_url is not null then jsonb_build_array(jsonb_build_object(
             'url', d.source_image_url, 'name', coalesce(d.doc_number,'bill'),
             'isImage', d.source_image_url ~* '\.(jpg|jpeg|png|webp|gif|heic)(\?|$)',
             'isPdf', d.source_image_url ~* '\.pdf(\?|$)')) else null end,
      d.created_at,
      jsonb_build_object('doc_slice_id', p_doc_id::text, 'project_id', pid, 'project_slice', true)
    from (
      select it->>'name' as nm,
             case when it->>'qty'    ~ '^-?[0-9.]+$' then (it->>'qty')::numeric    else null end as qty,
             it->>'uom' as uom,
             case when it->>'amount' ~ '^-?[0-9.]+$' then (it->>'amount')::numeric else null end as amt,
             ord
      from jsonb_array_elements(coalesce(d.items,'[]'::jsonb)) with ordinality as t(it, ord)
      where coalesce(nullif(it->>'project_id',''), d.project_id::text) = pid
    ) x;
  end loop;
exception when others then return;
end $fn$;

create or replace function public._trg_bill_project_channels() returns trigger
language plpgsql security definer as $fn$
begin
  perform public._sync_bill_project_channels(new.id);
  return new;
exception when others then return new;
end $fn$;
drop trigger if exists bill_project_channels_sync on public.mcp_logistics_documents;
create trigger bill_project_channels_sync
  after insert or update of items on public.mcp_logistics_documents
  for each row execute function public._trg_bill_project_channels();

do $$ declare r record; begin
  for r in select id from public.mcp_logistics_documents where plant_id = 'b1f10825-75e0-4a83-8de8-8941f47e5928' loop
    perform public._sync_bill_project_channels(r.id);
  end loop;
end $$;
