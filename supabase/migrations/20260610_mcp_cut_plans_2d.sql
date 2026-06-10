-- 2D plate cutting: same mcp_cut_plans table, with a plan_kind column to
-- distinguish bar-cutting from sheet-cutting plans. Pieces / stocks / materials
-- jsonb shapes differ per kind (1d has lengthMm, 2d has widthMm + heightMm).
alter table public.mcp_cut_plans
  add column if not exists plan_kind text not null default '1d'
    check (plan_kind in ('1d','2d'));

alter table public.mcp_cut_plans
  drop constraint if exists mcp_cut_plans_material_type_check;
alter table public.mcp_cut_plans
  add constraint mcp_cut_plans_material_type_check
  check (material_type in ('round_bar','square_bar','flat_bar','pipe','angle','channel','i_beam','plate','sheet_metal','other'));
