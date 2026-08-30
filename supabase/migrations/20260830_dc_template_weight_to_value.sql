-- DC print: replace the "Approx Weight" column with "Approx Value" (₹), bound to a
-- per-line approx_value entered on the DC. Applied via MCP; tracked mirror.
update public.mcp_record_templates
set config = jsonb_set(config, '{html}',
      to_jsonb(replace(replace(config->>'html', 'Approx Weight', 'Approx Value'),
        '{{item.gross_weight|number}}', '{{item.approx_value|currency}}')))
where plant_id = 'b1f10825-75e0-4a83-8de8-8941f47e5928' and active = true
  and config->>'html' like '%Approx Weight%';
