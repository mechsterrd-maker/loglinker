-- Extend the record-template source list so the AI format builder also
-- supports outward DC, returnable DC, PO, tax invoice, packing list, the two
-- job-work DC kinds and quotations. The renderer (rtRenderDocument /
-- rtBuildDocCtx) consumes any of them through the doc.* / item.* scopes.
alter table public.mcp_record_templates
  drop constraint if exists mcp_record_templates_source_check;

alter table public.mcp_record_templates
  add constraint mcp_record_templates_source_check
  check (source in (
    'petty_cash', 'expenses', 'shots', 'ncrs', 'documents', 'projects', 'mom', 'custom',
    'dc_out', 'dc_out_returnable', 'po', 'invoice_out', 'packing_list',
    'job_work_dc_out', 'job_work_dc_in', 'quote'
  ));
