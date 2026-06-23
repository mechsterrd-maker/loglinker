-- Additive per-plant module grants.
--
-- enabled_tabs is a *restrictive* whitelist (set it and the plant sees ONLY
-- those tabs). extra_modules is the opposite: an *additive* list that unlocks
-- specific opt-in modules (OPT_IN_TAB_KEYS on the client — attendance,
-- petty_cash, npd, …) for one plant WITHOUT touching the rest of its surface.
--
-- Used to roll a module out to a single plant for piloting, e.g. NPD on "wew"
-- only. NULL / empty = no extra grants.
ALTER TABLE public.plants
  ADD COLUMN IF NOT EXISTS extra_modules text[];
