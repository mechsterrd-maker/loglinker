-- "Starter" business type: when picked in the signup wizard, the new plant
-- gets only the 3 starter modules (attendance, petty_cash, actions) by
-- default. Plant owners can clear enabled_tabs / quick_entry_tiles back to
-- NULL later to unlock the full module surface.
CREATE OR REPLACE FUNCTION public.plants_apply_business_type_defaults()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.business_type = 'starter' THEN
    IF NEW.enabled_tabs IS NULL THEN
      NEW.enabled_tabs := ARRAY['attendance', 'petty_cash', 'actions'];
    END IF;
    IF NEW.quick_entry_tiles IS NULL THEN
      NEW.quick_entry_tiles := ARRAY['attendance', 'petty_cash', 'actions'];
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS plants_apply_business_type_defaults_trg ON public.plants;
CREATE TRIGGER plants_apply_business_type_defaults_trg
  BEFORE INSERT ON public.plants
  FOR EACH ROW EXECUTE FUNCTION public.plants_apply_business_type_defaults();
