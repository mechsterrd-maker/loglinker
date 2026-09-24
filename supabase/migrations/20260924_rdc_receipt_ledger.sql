-- RDC receiving ledger: a per-receipt history for each returnable DC so the RDC
-- screen can show "what came back and when" — returned material, cut parts (to a
-- project or to stock), reusable offcuts, weighed reusable, and scrap — instead of
-- scattering it across stock transactions and project components with no grouping.

create table if not exists public.mcp_rdc_receipts (
  id uuid primary key default gen_random_uuid(),
  plant_id uuid not null,
  unit_id uuid,
  doc_id uuid not null references public.mcp_logistics_documents(id) on delete cascade,
  received_on date,
  ref_no text,
  note text,
  lines jsonb not null default '[]'::jsonb,   -- [{kind,item_name,qty,uom,project_id,project_name,size_spec,note}]
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists idx_rdc_receipts_doc on public.mcp_rdc_receipts(doc_id, created_at desc);
create index if not exists idx_rdc_receipts_plant on public.mcp_rdc_receipts(plant_id);

alter table public.mcp_rdc_receipts enable row level security;
do $$ begin
  create policy rdc_receipts_sel on public.mcp_rdc_receipts for select using (plant_id = public.my_plant_id());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy rdc_receipts_ins on public.mcp_rdc_receipts for insert with check (plant_id = public.my_plant_id());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy rdc_receipts_del on public.mcp_rdc_receipts for delete using (plant_id = public.my_plant_id());
exception when duplicate_object then null; end $$;
grant select, insert, delete on public.mcp_rdc_receipts to authenticated;

-- One receipt event (a single "Save receipt") → one ledger row.
create or replace function public.log_rdc_receipt(p_doc_id uuid, p_received_on date, p_ref_no text, p_note text, p_lines jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_doc public.mcp_logistics_documents%rowtype; v_id uuid;
begin
  select * into v_doc from public.mcp_logistics_documents where id = p_doc_id;
  if v_doc.id is null then return jsonb_build_object('success', false, 'error', 'Document not found'); end if;
  if v_doc.plant_id <> public.my_plant_id() then return jsonb_build_object('success', false, 'error', 'No access'); end if;
  if coalesce(jsonb_array_length(p_lines), 0) = 0 then return jsonb_build_object('success', true, 'skipped', true); end if;
  insert into public.mcp_rdc_receipts (plant_id, unit_id, doc_id, received_on, ref_no, note, lines, created_by)
  values (v_doc.plant_id, v_doc.unit_id, p_doc_id, coalesce(p_received_on, current_date),
          nullif(btrim(p_ref_no), ''), nullif(btrim(p_note), ''), coalesce(p_lines, '[]'::jsonb), auth.uid())
  returning id into v_id;
  return jsonb_build_object('success', true, 'id', v_id);
exception when others then return jsonb_build_object('success', false, 'error', sqlerrm);
end $$;
grant execute on function public.log_rdc_receipt(uuid, date, text, text, jsonb) to authenticated;

-- Backfill history from existing stock movements (cut parts / offcuts / scrap that
-- were pushed to stock against a returnable DC). Groups the movements of one save
-- (same second) into a single receipt. Returned-uncut and project-assigned parts
-- from before this feature can't be reconstructed (they left no doc-linked txn);
-- everything from here on is captured live via log_rdc_receipt.
insert into public.mcp_rdc_receipts (plant_id, unit_id, doc_id, received_on, ref_no, note, lines, created_by, created_at)
select t.plant_id, (array_agg(d.unit_id order by t.created_at))[1], t.document_id, max(t.created_at)::date, null, 'Reconstructed from stock records',
  jsonb_agg(jsonb_build_object(
    'kind', case when t.reference = 'Offcut to stock' then 'offcut'
                 when t.reference = 'Scrap recorded'  then 'scrap'
                 when t.reference = 'Cut part to stock' then 'part_stock'
                 else 'return' end,
    'item_name', coalesce(si.name, 'Item'),
    'qty', t.qty, 'uom', si.uom,
    'size_spec', si.size_spec,
    'note', t.notes) order by t.created_at),
  (array_agg(t.performed_by order by t.created_at))[1], min(t.created_at)
from public.mcp_stocks_transactions t
join public.mcp_logistics_documents d on d.id = t.document_id and d.doc_type::text = 'dc_out_returnable'
left join public.mcp_stocks_items si on si.id = t.item_id
where t.document_id is not null
  and t.reference in ('Offcut to stock', 'Scrap recorded', 'Cut part to stock')
group by t.plant_id, t.document_id, date_trunc('second', t.created_at);
