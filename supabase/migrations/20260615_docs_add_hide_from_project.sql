-- Marvel 14-Jun MoM: when a bill is wrongly tagged to a project, give a
-- way to detach it WITHOUT deleting the document. hide_from_project keeps
-- the project_id (for audit traceability) but the project bills tab
-- filters out hide_from_project = true rows.
alter table public.mcp_logistics_documents
  add column if not exists hide_from_project boolean not null default false;
