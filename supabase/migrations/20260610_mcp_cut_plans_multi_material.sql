-- Multi-material plans: every plan now holds a list of materials, and every
-- piece + stock carries a material_id referencing one of them. Existing rows
-- get a single-material list synthesised from the legacy plan-level columns
-- (material_type, spec, density_kg_per_m3) and every piece/stock is reassigned
-- to that material's id ("m1").
alter table public.mcp_cut_plans
  add column if not exists materials jsonb not null default '[]'::jsonb;

update public.mcp_cut_plans
set
  materials = jsonb_build_array(
    jsonb_build_object(
      'id', 'm1',
      'type', coalesce(material_type, 'round_bar'),
      'spec', coalesce(spec, '{}'::jsonb),
      'density_kg_per_m3', coalesce(density_kg_per_m3, 7850),
      'kg_per_m', kg_per_m
    )
  ),
  pieces = coalesce((
    select jsonb_agg(case when p ? 'material_id' then p else p || jsonb_build_object('material_id', 'm1') end)
    from jsonb_array_elements(pieces) as p
  ), '[]'::jsonb),
  stocks = coalesce((
    select jsonb_agg(case when s ? 'material_id' then s else s || jsonb_build_object('material_id', 'm1') end)
    from jsonb_array_elements(stocks) as s
  ), '[]'::jsonb)
where materials = '[]'::jsonb or materials is null;
