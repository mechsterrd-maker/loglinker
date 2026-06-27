-- Starter Pack plants need the People tab to add employees and run the role
-- access matrix (we just turned RBAC on for them). Add 'people' to the starter
-- default tab whitelist and backfill the existing starter plants.

CREATE OR REPLACE FUNCTION public.plants_apply_business_type_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.business_type = 'starter' THEN
    IF NEW.enabled_tabs IS NULL THEN
      NEW.enabled_tabs := ARRAY['self_attendance', 'attendance', 'attendance_setup', 'petty_cash', 'actions', 'people'];
    END IF;
    IF NEW.quick_entry_tiles IS NULL THEN
      NEW.quick_entry_tiles := ARRAY['self_attendance', 'petty_cash', 'actions'];
    END IF;
    NEW.rbac_enforced := true;
    IF COALESCE(NEW.approval_status, 'pending') = 'pending' THEN
      NEW.approval_status := 'approved';
      IF NEW.approval_decided_at IS NULL THEN
        NEW.approval_decided_at := now();
      END IF;
      IF NEW.approval_note IS NULL THEN
        NEW.approval_note := 'Auto-approved · Starter Pack (no payment gate)';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $function$;

-- Backfill existing starter plants: append 'people' if missing.
UPDATE public.plants
SET enabled_tabs = array_append(enabled_tabs, 'people')
WHERE business_type = 'starter'
  AND NOT ('people' = ANY(COALESCE(enabled_tabs, ARRAY[]::text[])));
