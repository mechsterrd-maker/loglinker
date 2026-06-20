-- Two overloads of update_plant_role existed:
--   1. (uuid, text, text, boolean)                  — old, 4 args
--   2. (uuid, text, text, boolean, integer DEFAULT) — new, sort-order aware
-- Client calls both forms (with and without p_sort_order). Postgres can't
-- pick between them when 4 args are passed because the 5-arg version's
-- default makes it match too. Drop the legacy 4-arg version; the 5-arg
-- version handles both call sites via its DEFAULT NULL on p_sort_order.
DROP FUNCTION IF EXISTS public.update_plant_role(uuid, text, text, boolean);
