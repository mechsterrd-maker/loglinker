-- Per-item tracking for sales Returnable DCs (dc_out_returnable): what went out on
-- returnable basis, how much came back, when closed. Feeds the "RDC Returns" module
-- (Daily Operations) and the Documents > Returnables tab.
create table if not exists public.mcp_rdc_lines (
  id uuid primary key default gen_random_uuid(),
  plant_id uuid not null references public.plants(id) on delete cascade,
  unit_id uuid references public.units(id) on delete set null,
  doc_id uuid not null references public.mcp_logistics_documents(id) on delete cascade,
  item_idx int not null,
  party_name text, item_name text, hsn text, uom text,
  qty_sent numeric not null default 0,
  qty_received numeric not null default 0,
  expected_return_date date,
  status text not null default 'open',        -- open | partial | received | closed
  sent_on date, received_at timestamptz, closed_at timestamptz,
  closed_by uuid references public.users(id) on delete set null,
  created_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (doc_id, item_idx)
);
create index if not exists idx_rdc_lines_plant on public.mcp_rdc_lines(plant_id, status);

alter table public.mcp_rdc_lines enable row level security;
drop policy if exists mcp_rdc_lines_sel on public.mcp_rdc_lines;
drop policy if exists mcp_rdc_lines_all on public.mcp_rdc_lines;
drop policy if exists unit_iso on public.mcp_rdc_lines;
create policy mcp_rdc_lines_sel on public.mcp_rdc_lines for select to authenticated using (plant_id = my_plant_id());
create policy mcp_rdc_lines_all on public.mcp_rdc_lines for all to authenticated using (plant_id = my_plant_id()) with check (plant_id = my_plant_id());
create policy unit_iso on public.mcp_rdc_lines as restrictive for all to authenticated using (public.unit_visible(unit_id)) with check (public.unit_visible(unit_id));

create or replace function public.sync_rdc_lines_from_doc() returns trigger language plpgsql security definer as $$
begin
  if NEW.doc_type::text <> 'dc_out_returnable' then return NEW; end if;
  if NEW.items is null or jsonb_typeof(NEW.items) <> 'array' then return NEW; end if;
  insert into public.mcp_rdc_lines (plant_id, unit_id, doc_id, item_idx, party_name, item_name, hsn, uom, qty_sent, sent_on, created_by)
  select NEW.plant_id, NEW.unit_id, NEW.id, t.ord::int,
    coalesce(NEW.vendor_name_raw, (select name from mcp_logistics_vendors where id = NEW.vendor_id)),
    coalesce(t.it->>'name', t.it->>'item_name'), t.it->>'hsn', t.it->>'uom',
    coalesce(nullif(t.it->>'qty','')::numeric, 0), coalesce(NEW.doc_date, current_date), NEW.created_by
  from jsonb_array_elements(NEW.items) with ordinality as t(it, ord)
  where coalesce(nullif(t.it->>'qty','')::numeric, 0) > 0
  on conflict (doc_id, item_idx) do update
    set qty_sent = excluded.qty_sent, item_name = excluded.item_name,
        party_name = excluded.party_name, hsn = excluded.hsn, uom = excluded.uom, updated_at = now()
    where mcp_rdc_lines.status in ('open','partial');
  return NEW;
exception when others then raise warning 'sync_rdc_lines_from_doc failed for %: %', NEW.id, sqlerrm; return NEW;
end $$;

drop trigger if exists trg_sync_rdc_lines on public.mcp_logistics_documents;
create trigger trg_sync_rdc_lines after insert or update of items, doc_number, doc_date, vendor_name_raw
  on public.mcp_logistics_documents for each row
  when (new.doc_type::text = 'dc_out_returnable')
  execute function public.sync_rdc_lines_from_doc();

insert into public.mcp_rdc_lines (plant_id, unit_id, doc_id, item_idx, party_name, item_name, hsn, uom, qty_sent, sent_on, created_by)
select d.plant_id, d.unit_id, d.id, t.ord::int, coalesce(d.vendor_name_raw, v.name),
  coalesce(t.it->>'name', t.it->>'item_name'), t.it->>'hsn', t.it->>'uom',
  coalesce(nullif(t.it->>'qty','')::numeric, 0), coalesce(d.doc_date, current_date), d.created_by
from public.mcp_logistics_documents d
  left join public.mcp_logistics_vendors v on v.id = d.vendor_id,
  lateral jsonb_array_elements(coalesce(d.items,'[]'::jsonb)) with ordinality as t(it, ord)
where d.doc_type = 'dc_out_returnable' and coalesce(nullif(t.it->>'qty','')::numeric, 0) > 0
on conflict (doc_id, item_idx) do nothing;

create or replace function public.receive_rdc_line(p_line_id uuid, p_qty numeric)
returns jsonb language plpgsql security definer as $$
declare v_line public.mcp_rdc_lines%rowtype; v_new numeric;
begin
  select * into v_line from public.mcp_rdc_lines where id = p_line_id;
  if v_line.id is null then return jsonb_build_object('success', false, 'error', 'Line not found'); end if;
  if v_line.plant_id is distinct from my_plant_id() then return jsonb_build_object('success', false, 'error', 'No access'); end if;
  v_new := least(coalesce(v_line.qty_received,0) + greatest(coalesce(p_qty,0),0), v_line.qty_sent);
  update public.mcp_rdc_lines
    set qty_received = v_new,
        status = case when v_new >= qty_sent then 'received' when v_new > 0 then 'partial' else 'open' end,
        received_at = case when v_new >= qty_sent then now() else received_at end, updated_at = now()
  where id = p_line_id;
  return jsonb_build_object('success', true);
end $$;

create or replace function public.close_rdc_line(p_line_id uuid, p_reopen boolean default false)
returns jsonb language plpgsql security definer as $$
declare v_line public.mcp_rdc_lines%rowtype;
begin
  select * into v_line from public.mcp_rdc_lines where id = p_line_id;
  if v_line.id is null then return jsonb_build_object('success', false, 'error', 'Line not found'); end if;
  if v_line.plant_id is distinct from my_plant_id() then return jsonb_build_object('success', false, 'error', 'No access'); end if;
  update public.mcp_rdc_lines
    set status = case when p_reopen then (case when qty_received >= qty_sent then 'received' when qty_received > 0 then 'partial' else 'open' end) else 'closed' end,
        closed_at = case when p_reopen then null else now() end,
        closed_by = case when p_reopen then null else auth.uid() end, updated_at = now()
  where id = p_line_id;
  return jsonb_build_object('success', true);
end $$;

create or replace function public.set_rdc_expected_return(p_line_id uuid, p_date date)
returns jsonb language plpgsql security definer as $$
begin
  if not exists (select 1 from public.mcp_rdc_lines where id = p_line_id and plant_id = my_plant_id()) then
    return jsonb_build_object('success', false, 'error', 'No access');
  end if;
  update public.mcp_rdc_lines set expected_return_date = p_date, updated_at = now() where id = p_line_id;
  return jsonb_build_object('success', true);
end $$;

grant execute on function public.receive_rdc_line(uuid, numeric) to authenticated;
grant execute on function public.close_rdc_line(uuid, boolean) to authenticated;
grant execute on function public.set_rdc_expected_return(uuid, date) to authenticated;

-- Documents > Returnables now reads RDCs from the tracked lines (received/closed drop off).
CREATE OR REPLACE VIEW public.v_returnables_open AS
 SELECT jl.id, jl.plant_id, jl.doc_id, d.doc_number, d.doc_date AS sent_on, jl.vendor_id,
    v.name AS vendor_name, v.is_jobwork_vendor, jl.item_id, jl.stock_item_id, jl.item_name,
    jl.hsn, jl.uom, jl.process, jl.qty_sent,
    COALESCE(jl.qty_received_back, 0::numeric) AS qty_received_back,
    GREATEST(jl.qty_sent - COALESCE(jl.qty_received_back, 0::numeric), 0::numeric) AS qty_pending,
    jl.status, jl.sla_days, jl.expected_return_date, jl.last_received_at, jl.created_at AS sent_at,
    EXTRACT(day FROM now() - jl.created_at)::integer AS days_pending,
        CASE WHEN jl.expected_return_date IS NULL THEN NULL::integer ELSE EXTRACT(day FROM now() - jl.expected_return_date::timestamp without time zone::timestamp with time zone)::integer END AS days_overdue,
        CASE WHEN jl.expected_return_date IS NOT NULL AND jl.expected_return_date < CURRENT_DATE THEN true ELSE false END AS sla_breached,
    jl.unit_id, 'jobwork'::text AS source
   FROM mcp_logistics_jobwork_lines jl
     LEFT JOIN mcp_logistics_vendors v ON v.id = jl.vendor_id
     LEFT JOIN mcp_logistics_documents d ON d.id = jl.doc_id
  WHERE jl.status = ANY (ARRAY['open'::text, 'partial'::text])
UNION ALL
 SELECT rl.id, rl.plant_id, rl.doc_id, d.doc_number, rl.sent_on AS sent_on, d.vendor_id,
    rl.party_name AS vendor_name, false AS is_jobwork_vendor, NULL::uuid AS item_id,
    NULL::uuid AS stock_item_id, rl.item_name, rl.hsn, rl.uom, NULL::text AS process,
    rl.qty_sent::numeric(14,3) AS qty_sent,
    COALESCE(rl.qty_received, 0::numeric) AS qty_received_back,
    GREATEST(rl.qty_sent - COALESCE(rl.qty_received, 0::numeric), 0::numeric) AS qty_pending,
    rl.status, NULL::integer AS sla_days, rl.expected_return_date, rl.received_at AS last_received_at,
    rl.created_at AS sent_at, EXTRACT(day FROM now() - rl.created_at)::integer AS days_pending,
        CASE WHEN rl.expected_return_date IS NULL THEN NULL::integer ELSE EXTRACT(day FROM now() - rl.expected_return_date::timestamp without time zone::timestamp with time zone)::integer END AS days_overdue,
        CASE WHEN rl.expected_return_date IS NOT NULL AND rl.expected_return_date < CURRENT_DATE THEN true ELSE false END AS sla_breached,
    rl.unit_id, 'returnable_dc'::text AS source
   FROM mcp_rdc_lines rl
     LEFT JOIN mcp_logistics_documents d ON d.id = rl.doc_id
  WHERE rl.status = ANY (ARRAY['open'::text, 'partial'::text]);

insert into public.role_permissions (role_id, module_key, action)
select pr.id, 'rdc_returns', '*' from public.plant_roles pr where pr.is_builtin
on conflict do nothing;
