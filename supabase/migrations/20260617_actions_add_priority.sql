-- Add priority to actions. Text + check constraint (not enum) so we can
-- extend later without an ALTER TYPE dance. Default 'medium' so existing
-- rows + manual entries that don't pick get a safe value.
ALTER TABLE public.actions
  ADD COLUMN IF NOT EXISTS priority text NOT NULL DEFAULT 'medium';

ALTER TABLE public.actions
  DROP CONSTRAINT IF EXISTS actions_priority_check;

ALTER TABLE public.actions
  ADD CONSTRAINT actions_priority_check
  CHECK (priority IN ('low', 'medium', 'high'));

-- Index so "show high-priority open tasks" stays fast as the table grows.
CREATE INDEX IF NOT EXISTS actions_priority_status_idx
  ON public.actions (plant_id, priority, status)
  WHERE status IN ('open', 'in_progress');
