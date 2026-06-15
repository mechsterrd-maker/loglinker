-- Marvel's 14-Jun MoM: a task is "for a project" — replace the Department
-- picker with a Project picker. Adds a nullable FK so legacy / non-project
-- tasks (e.g. NCR-derived, MoM-derived auto-tasks) keep working.
alter table public.actions
  add column if not exists project_id uuid references public.mcp_projects(id) on delete set null;

create index if not exists idx_actions_project on public.actions(project_id) where project_id is not null;
