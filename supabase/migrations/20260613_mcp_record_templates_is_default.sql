-- Per-(plant, source) default flag. Only one default per doc type per
-- plant so the create form and the preview can auto-select it; the user
-- can still pick a different one from the dropdown.
alter table public.mcp_record_templates
  add column if not exists is_default boolean not null default false;

create unique index if not exists mcp_record_templates_default_per_source
  on public.mcp_record_templates(plant_id, source)
  where is_default = true and active = true;
