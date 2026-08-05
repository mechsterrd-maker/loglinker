-- Fettling jobs carry a part number too, so same-named castings (e.g. several
-- "IMF" variants: 54S30053, 54S30084 …) stay distinct. The daily log snapshots it
-- alongside the name + rate.
alter table public.fettling_parts add column if not exists part_number text;
alter table public.fettling_log  add column if not exists part_number text;
