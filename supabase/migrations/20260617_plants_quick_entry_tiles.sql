-- Per-plant override for the Home → Quick Entry tile set.
-- NULL = use the platform default (fab vs non-fab tile list).
-- Non-empty array = show only tiles whose tab key is in the list.
ALTER TABLE public.plants
  ADD COLUMN IF NOT EXISTS quick_entry_tiles text[];

-- Krishnas Fittings is starting with a task-first workflow.
UPDATE public.plants
  SET quick_entry_tiles = ARRAY['actions', 'chat']
  WHERE name ILIKE '%krishna%';
