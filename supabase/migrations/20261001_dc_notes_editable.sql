-- Make the DC/RDC print note editable. The MMPL Delivery Challan template had
-- "* Not For Sale / * Material for Machining & Returnable" hardcoded before
-- {{doc.notes}}, so it always printed even when the material wasn't for
-- machining/laser. Move the whole note into the editable {{doc.notes}} field.

-- 1) Preserve existing challans' prints: prepend the two standard lines into
--    their notes (idempotent) so reprints look identical to before.
update public.mcp_logistics_documents
set notes = '* Not For Sale' || chr(10) || '* Material for Machining & Returnable'
            || case when coalesce(trim(notes),'') = '' then '' else chr(10) || notes end
where plant_id = 'b1f10825-75e0-4a83-8de8-8941f47e5928'
  and doc_type in ('dc_out','dc_out_returnable')
  and coalesce(notes,'') not ilike '%not for sale%';

-- 2) Template prints ONLY the editable {{doc.notes}} now.
update public.mcp_record_templates
set config = jsonb_set(config, '{html}',
      to_jsonb(replace(config->>'html',
        '* Not For Sale<br>* Material for Machining & Returnable<br>{{doc.notes}}',
        '{{doc.notes}}'))),
    updated_at = now()
where id = '931516aa-7412-4200-87dd-8da7a04eeee2';
