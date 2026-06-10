-- Cut plans: add material type, cross-section spec, density, and computed kg/m.
-- Existing rows default to round_bar with an empty spec so legacy plans still
-- load (UI prompts for the diameter).
alter table public.mcp_cut_plans
  add column if not exists material_type text not null default 'round_bar'
    check (material_type in ('round_bar','square_bar','flat_bar','pipe','angle','channel','i_beam','other')),
  add column if not exists spec jsonb not null default '{}'::jsonb,
  add column if not exists density_kg_per_m3 numeric not null default 7850,
  add column if not exists kg_per_m numeric;
