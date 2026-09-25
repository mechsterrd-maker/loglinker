-- Doc numbers pad the running sequence to 3 digits (001) instead of 4 (0001),
-- for get_next_ and peek_ (both the plain and unit-aware overloads).
CREATE OR REPLACE FUNCTION public.get_next_logistics_doc_number(p_plant_id uuid, p_doc_kind text, p_date date DEFAULT CURRENT_DATE)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_fy text; v_seq int; v_prefix text;
begin
  v_fy := indian_fy(p_date);
  select case p_doc_kind
      when 'dc'           then coalesce(nullif(p.dc_prefix,''),      regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/DC'
      when 'rdc'          then coalesce(nullif(p.rdc_prefix,''),     nullif(p.dc_prefix,''), regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/RDC'
      when 'invoice'      then coalesce(nullif(p.invoice_prefix,''), nullif(p.dc_prefix,''), regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/INV'
      when 'po'           then coalesce(nullif(p.dc_prefix,''),      regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/PO'
      when 'packing'      then coalesce(nullif(p.dc_prefix,''),      regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/PL'
      when 'jobwork_dc'   then coalesce(nullif(p.dc_prefix,''),      regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/JW'
      when 'interunit_dc' then coalesce(nullif(p.dc_prefix,''),      regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/IU'
      when 'quote'        then coalesce(nullif(p.dc_prefix,''),      regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/QT'
      else coalesce(nullif(p.dc_prefix,''), regexp_replace(upper(p.name),'[^A-Z0-9]','','g'))
    end into v_prefix from plants p where id = p_plant_id;
  if length(split_part(v_prefix,'/',1)) > 8 then
    v_prefix := substring(split_part(v_prefix,'/',1),1,8) || '/' || split_part(v_prefix,'/',2);
  end if;
  insert into mcp_logistics_doc_counters (plant_id, doc_kind, fy, next_seq, updated_at)
  values (p_plant_id, p_doc_kind, v_fy, 2, now())
  on conflict (plant_id, doc_kind, fy)
  do update set next_seq = mcp_logistics_doc_counters.next_seq + 1, updated_at = now()
  returning next_seq - 1 into v_seq;
  return v_prefix || '/' || v_fy || '/' || lpad(v_seq::text, 3, '0');
end $function$;

CREATE OR REPLACE FUNCTION public.get_next_logistics_doc_number(p_plant_id uuid, p_doc_kind text, p_date date DEFAULT CURRENT_DATE, p_unit_id uuid DEFAULT NULL::uuid)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_fy text; v_seq int; v_base text; v_kind text; v_code text; v_prefix text;
begin
  v_fy := indian_fy(p_date);
  select case p_doc_kind
      when 'dc'           then coalesce(nullif(p.dc_prefix,''),      regexp_replace(upper(p.name),'[^A-Z0-9]','','g'))
      when 'rdc'          then coalesce(nullif(p.rdc_prefix,''),     nullif(p.dc_prefix,''), regexp_replace(upper(p.name),'[^A-Z0-9]','','g'))
      when 'invoice'      then coalesce(nullif(p.invoice_prefix,''), nullif(p.dc_prefix,''), regexp_replace(upper(p.name),'[^A-Z0-9]','','g'))
      else coalesce(nullif(p.dc_prefix,''), regexp_replace(upper(p.name),'[^A-Z0-9]','','g'))
    end into v_base from plants p where id = p_plant_id;
  if length(v_base) > 8 then v_base := substring(v_base,1,8); end if;
  v_kind := case p_doc_kind
      when 'dc' then 'DC' when 'rdc' then 'RDC' when 'invoice' then 'INV' when 'po' then 'PO'
      when 'packing' then 'PL' when 'jobwork_dc' then 'JW' when 'interunit_dc' then 'IU' when 'quote' then 'QT'
      else 'DOC' end;
  if p_unit_id is not null then select nullif(trim(code),'') into v_code from units where id = p_unit_id; end if;
  v_prefix := v_base || case when coalesce(v_code,'') <> '' then '/' || v_code else '' end || '/' || v_kind;
  insert into mcp_logistics_doc_counters (plant_id, unit_id, doc_kind, fy, next_seq, updated_at)
  values (p_plant_id, p_unit_id, p_doc_kind, v_fy, 2, now())
  on conflict (plant_id, doc_kind, fy, coalesce(unit_id, '00000000-0000-0000-0000-000000000000'::uuid))
  do update set next_seq = mcp_logistics_doc_counters.next_seq + 1, updated_at = now()
  returning next_seq - 1 into v_seq;
  return v_prefix || '/' || v_fy || '/' || lpad(v_seq::text, 3, '0');
end $function$;

CREATE OR REPLACE FUNCTION public.peek_next_logistics_doc_number(p_plant_id uuid, p_doc_kind text, p_date date DEFAULT CURRENT_DATE)
 RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_fy text; v_seq int; v_prefix text;
begin
  v_fy := indian_fy(p_date);
  select case p_doc_kind
      when 'dc'           then coalesce(nullif(p.dc_prefix,''),      regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/DC'
      when 'rdc'          then coalesce(nullif(p.rdc_prefix,''),     nullif(p.dc_prefix,''), regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/RDC'
      when 'invoice'      then coalesce(nullif(p.invoice_prefix,''), nullif(p.dc_prefix,''), regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/INV'
      when 'po'           then coalesce(nullif(p.dc_prefix,''),      regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/PO'
      when 'packing'      then coalesce(nullif(p.dc_prefix,''),      regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/PL'
      when 'jobwork_dc'   then coalesce(nullif(p.dc_prefix,''),      regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/JW'
      when 'interunit_dc' then coalesce(nullif(p.dc_prefix,''),      regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/IU'
      when 'quote'        then coalesce(nullif(p.dc_prefix,''),      regexp_replace(upper(p.name),'[^A-Z0-9]','','g')) || '/QT'
      else coalesce(nullif(p.dc_prefix,''), regexp_replace(upper(p.name),'[^A-Z0-9]','','g'))
    end into v_prefix from plants p where id = p_plant_id;
  if length(split_part(v_prefix,'/',1)) > 8 then
    v_prefix := substring(split_part(v_prefix,'/',1),1,8) || '/' || split_part(v_prefix,'/',2);
  end if;
  select coalesce(next_seq, 1) into v_seq from mcp_logistics_doc_counters
    where plant_id = p_plant_id and doc_kind = p_doc_kind and fy = v_fy;
  if v_seq is null then v_seq := 1; end if;
  return v_prefix || '/' || v_fy || '/' || lpad(v_seq::text, 3, '0');
end $function$;

CREATE OR REPLACE FUNCTION public.peek_next_logistics_doc_number(p_plant_id uuid, p_doc_kind text, p_date date DEFAULT CURRENT_DATE, p_unit_id uuid DEFAULT NULL::uuid)
 RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_fy text; v_seq int; v_base text; v_kind text; v_code text; v_prefix text;
begin
  v_fy := indian_fy(p_date);
  select case p_doc_kind
      when 'dc'           then coalesce(nullif(p.dc_prefix,''),      regexp_replace(upper(p.name),'[^A-Z0-9]','','g'))
      when 'rdc'          then coalesce(nullif(p.rdc_prefix,''),     nullif(p.dc_prefix,''), regexp_replace(upper(p.name),'[^A-Z0-9]','','g'))
      when 'invoice'      then coalesce(nullif(p.invoice_prefix,''), nullif(p.dc_prefix,''), regexp_replace(upper(p.name),'[^A-Z0-9]','','g'))
      else coalesce(nullif(p.dc_prefix,''), regexp_replace(upper(p.name),'[^A-Z0-9]','','g'))
    end into v_base from plants p where id = p_plant_id;
  if length(v_base) > 8 then v_base := substring(v_base,1,8); end if;
  v_kind := case p_doc_kind
      when 'dc' then 'DC' when 'rdc' then 'RDC' when 'invoice' then 'INV' when 'po' then 'PO'
      when 'packing' then 'PL' when 'jobwork_dc' then 'JW' when 'interunit_dc' then 'IU' when 'quote' then 'QT'
      else 'DOC' end;
  if p_unit_id is not null then select nullif(trim(code),'') into v_code from units where id = p_unit_id; end if;
  v_prefix := v_base || case when coalesce(v_code,'') <> '' then '/' || v_code else '' end || '/' || v_kind;
  select coalesce(next_seq, 1) into v_seq from mcp_logistics_doc_counters
    where plant_id = p_plant_id and doc_kind = p_doc_kind and fy = v_fy
      and coalesce(unit_id, '00000000-0000-0000-0000-000000000000'::uuid) = coalesce(p_unit_id, '00000000-0000-0000-0000-000000000000'::uuid);
  if v_seq is null then v_seq := 1; end if;
  return v_prefix || '/' || v_fy || '/' || lpad(v_seq::text, 3, '0');
end $function$;

-- One-off: enlarge the small "For <company>" line in MMPL's Delivery Challan
-- print template (was 11px + nowrap, so the long legal name printed tiny).
update public.mcp_record_templates
set config = jsonb_set(config, '{html}',
      to_jsonb(replace(config->>'html',
        '<span style="white-space:nowrap;font-size:11px"><strong>For {{plant.legal_name}}</strong></span>',
        '<span style="font-size:13.5px;font-weight:700"><strong>For {{plant.legal_name}}</strong></span>'))),
    updated_at = now()
where id = '931516aa-7412-4200-87dd-8da7a04eeee2';
