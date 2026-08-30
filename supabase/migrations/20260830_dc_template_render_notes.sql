-- The DC print didn't render doc.notes (plan items / remarks). Add {{doc.notes}} to
-- the "Not For Sale" remarks cell with white-space:pre-wrap so its line breaks show.
-- Applied via MCP; tracked mirror.
update public.mcp_record_templates
set config = jsonb_set(config, '{html}', to_jsonb(
      replace(replace(config->>'html',
        'padding:5px">* Not For Sale', 'padding:5px;white-space:pre-wrap">* Not For Sale'),
        'Material for Machining & Returnable</td>', 'Material for Machining & Returnable<br>{{doc.notes}}</td>')))
where plant_id = 'b1f10825-75e0-4a83-8de8-8941f47e5928' and active = true
  and config->>'html' like '%Material for Machining %';
