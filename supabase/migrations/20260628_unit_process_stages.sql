-- Per-unit production processes. Each unit is a separate factory with its own
-- stages. NULL = not configured: the app derives the stage list from the unit's
-- machines, and falls back to the full catalog only when the unit has no
-- machines yet. A non-null array is the explicit list of LOG_TEMPLATES keys
-- this unit runs (e.g. {'cnc','vmc','lathe'}).
ALTER TABLE public.units ADD COLUMN IF NOT EXISTS process_stages text[];
