-- "For <company>" signatory line still felt small at 13.5px — bump to 16px.
update public.mcp_record_templates
set config = jsonb_set(config, '{html}',
      to_jsonb(replace(config->>'html',
        '<span style="font-size:13.5px;font-weight:700"><strong>For {{plant.legal_name}}</strong></span>',
        '<span style="font-size:16px;font-weight:700"><strong>For {{plant.legal_name}}</strong></span>'))),
    updated_at = now()
where id = '931516aa-7412-4200-87dd-8da7a04eeee2';
