-- ROOT CAUSE FIX + BACKFILL for missing project consumption from DCs/RDCs.
--
-- mcp_project_material_usage had RLS enabled with only a SELECT policy. The
-- cascade_stock_out_on_dc trigger is a plain (non-SECURITY DEFINER) function, so
-- when a user saved a DC it ran as that user with RLS enforced. The consumption
-- INSERT was silently denied (no INSERT policy → default deny), the error was
-- swallowed by the trigger's isolated exception block, and the result was: stock
-- got deducted but the project expense row was NEVER created. Manual "issue to
-- project" worked only because that RPC is SECURITY DEFINER (bypasses RLS).
--
-- Part 1: add INSERT / UPDATE / DELETE policies scoped to the caller's plant so
--         the trigger (and any future non-definer writer) can record consumption.
-- Part 2: backfill the project consumption for every past DC/RDC line that was
--         tagged to a project, actually moved stock, but has no usage row yet.

-- Part 1 --------------------------------------------------------------------
do $$ begin
  create policy pmu_insert on public.mcp_project_material_usage
    for insert with check (plant_id = public.my_plant_id());
exception when duplicate_object then null; end $$;

do $$ begin
  create policy pmu_update on public.mcp_project_material_usage
    for update using (plant_id = public.my_plant_id()) with check (plant_id = public.my_plant_id());
exception when duplicate_object then null; end $$;

do $$ begin
  create policy pmu_delete on public.mcp_project_material_usage
    for delete using (plant_id = public.my_plant_id());
exception when duplicate_object then null; end $$;

-- Part 2 --------------------------------------------------------------------
do $$
declare
  r record; v_item public.mcp_stocks_items%rowtype;
  v_price numeric; v_txn uuid; v_stock_id uuid;
begin
  for r in
    select d.id as doc_id, d.plant_id, d.unit_id, d.created_by, d.doc_number,
           d.doc_type::text as dt, d.vendor_id,
           (it->>'project_id')::uuid as project_id,
           nullif(it->>'stock_item_id','') as raw_stock_id,
           coalesce(it->>'name', it->>'item_name') as nm,
           it->>'hsn' as hsn,
           coalesce((it->>'qty')::numeric, 0) as qty
    from public.mcp_logistics_documents d
    cross join lateral jsonb_array_elements(coalesce(d.items, '[]'::jsonb)) it
    where d.doc_type::text in ('dc_out', 'dc_out_returnable')
      and (d.status is null or d.status::text <> 'cancelled')
      and coalesce(d.raw_extraction->>'subcontract_plan_id', '') = ''
      and (it->>'project_id') ~ '^[0-9a-fA-F-]{36}$'
      and coalesce((it->>'qty')::numeric, 0) > 0
  loop
    -- Resolve the stock item exactly as the cascade would have.
    v_stock_id := null;
    if r.raw_stock_id is not null then
      begin v_stock_id := r.raw_stock_id::uuid; exception when others then v_stock_id := null; end;
      if v_stock_id is not null then
        perform 1 from public.mcp_stocks_items where id = v_stock_id and plant_id = r.plant_id;
        if not found then v_stock_id := null; end if;
      end if;
    end if;
    if v_stock_id is null then
      v_stock_id := public.resolve_stock_item_for_line(r.plant_id, r.vendor_id, r.nm, r.hsn);
    end if;
    if v_stock_id is null then continue; end if;

    if not exists (select 1 from public.mcp_projects where id = r.project_id and plant_id = r.plant_id) then
      continue;
    end if;

    -- Only count a line that actually moved stock (an 'issue' txn exists for it).
    select id into v_txn
      from public.mcp_stocks_transactions
      where document_id = r.doc_id and item_id = v_stock_id and txn_type = 'issue'
      order by created_at limit 1;
    if v_txn is null then continue; end if;

    -- Idempotent: skip if this exact line was already recorded / backfilled.
    if exists (
      select 1 from public.mcp_project_material_usage
      where document_id = r.doc_id and item_id = v_stock_id
        and project_id = r.project_id and qty = r.qty
    ) then continue; end if;

    select * into v_item from public.mcp_stocks_items where id = v_stock_id;
    v_price := public.last_purchase_rate(v_stock_id);

    insert into public.mcp_project_material_usage
      (plant_id, unit_id, project_id, item_id, item_name, uom, size_spec, unit_weight,
       qty, total_weight, unit_price, amount, price_source, stock_txn_id, document_id, note, created_by, created_at)
    values
      (r.plant_id, r.unit_id, r.project_id, v_stock_id, v_item.name, v_item.uom, v_item.size_spec, v_item.unit_weight,
       r.qty, round(coalesce(v_item.unit_weight, 0) * r.qty, 3), v_price, round(r.qty * coalesce(v_price, 0), 2),
       case when coalesce(v_price, 0) > 0 then 'last_purchase' else 'none' end,
       v_txn, r.doc_id,
       'Backfill from ' || case when r.dt = 'dc_out_returnable' then 'RDC ' else 'DC ' end || coalesce(r.doc_number, ''),
       r.created_by, now());
  end loop;
end $$;
