-- Allow a single bill/invoice to be linked to several projects (associative).
-- project_id stays the primary link (used by cost / per-line rollups); project_ids
-- holds every linked project (including the primary) so the bill can appear under
-- each of them. Backfill from the existing single link.
alter table mcp_logistics_documents
  add column if not exists project_ids jsonb not null default '[]'::jsonb;

update mcp_logistics_documents
  set project_ids = jsonb_build_array(project_id::text)
  where project_id is not null
    and (project_ids is null or project_ids = '[]'::jsonb);

create index if not exists idx_docs_project_ids on mcp_logistics_documents using gin (project_ids);
