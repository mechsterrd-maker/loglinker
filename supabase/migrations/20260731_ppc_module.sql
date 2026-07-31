-- Production Planning & Control (PPC) — plan work per stage per day, assign
-- operators, and track planned-vs-actual output. Built for a pressure-die-casting
-- fittings line (PDC → Fettling → Shot blasting → CNC/VMC → Final inspection →
-- Dispatch) but stage list + cadence are editable per plant. Plant-scoped +
-- unit-isolated like the rest of the app. Operators are a lightweight manual list
-- (floor workers who may not have login accounts).

-- ── Process stages (the line) ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ppc_stages (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id    uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id     uuid REFERENCES public.units(id) ON DELETE SET NULL,
  name        text NOT NULL,
  seq         int  NOT NULL DEFAULT 0,             -- order in the line
  cadence     text NOT NULL DEFAULT 'daily',       -- weekly | daily
  active      boolean NOT NULL DEFAULT true,
  created_by  uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ppc_stages_plant ON public.ppc_stages(plant_id, seq);

-- ── Part master (what they make) ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ppc_parts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id    uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id     uuid REFERENCES public.units(id) ON DELETE SET NULL,
  code        text,
  name        text NOT NULL,
  uom         text NOT NULL DEFAULT 'pcs',
  active      boolean NOT NULL DEFAULT true,
  created_by  uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ppc_parts_plant ON public.ppc_parts(plant_id, active);

-- ── Operators (manual floor-worker list) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ppc_operators (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id    uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id     uuid REFERENCES public.units(id) ON DELETE SET NULL,
  name        text NOT NULL,
  skill       text,                                -- optional: stage/skill note
  active      boolean NOT NULL DEFAULT true,
  created_by  uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ppc_operators_plant ON public.ppc_operators(plant_id, active);

-- ── Monthly requirement (demand) ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ppc_month_plan (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id      uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id       uuid REFERENCES public.units(id) ON DELETE SET NULL,
  part_id       uuid NOT NULL REFERENCES public.ppc_parts(id) ON DELETE CASCADE,
  month         date NOT NULL,                     -- first day of the month
  target_qty    numeric NOT NULL DEFAULT 0,
  working_days  int NOT NULL DEFAULT 26,           -- to derive daily target
  notes         text,
  created_by    uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ppc_month_plan ON public.ppc_month_plan(plant_id, month);

-- ── Scheduled jobs (one stage, one day; weekly & daily both live here) ────
CREATE TABLE IF NOT EXISTS public.ppc_plan (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id      uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id       uuid REFERENCES public.units(id) ON DELETE SET NULL,
  plan_date     date NOT NULL,
  stage_id      uuid NOT NULL REFERENCES public.ppc_stages(id) ON DELETE CASCADE,
  part_id       uuid REFERENCES public.ppc_parts(id) ON DELETE SET NULL,
  planned_qty   numeric NOT NULL DEFAULT 0,
  machine       text,                              -- PDC die / CNC-VMC machine no.
  setting_note  text,                              -- CNC/VMC emergency setting change
  operator_ids  uuid[] NOT NULL DEFAULT '{}',      -- assigned ppc_operators ids
  status        text NOT NULL DEFAULT 'planned',   -- planned | in_progress | done | hold
  notes         text,
  created_by    uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ppc_plan_date ON public.ppc_plan(plant_id, plan_date, stage_id);

-- ── Actual output (tracking; per operator) ───────────────────────────────
CREATE TABLE IF NOT EXISTS public.ppc_output (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id      uuid NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
  unit_id       uuid REFERENCES public.units(id) ON DELETE SET NULL,
  plan_id       uuid NOT NULL REFERENCES public.ppc_plan(id) ON DELETE CASCADE,
  operator_id   uuid REFERENCES public.ppc_operators(id) ON DELETE SET NULL,
  log_date      date NOT NULL,
  ok_qty        numeric NOT NULL DEFAULT 0,
  reject_qty    numeric NOT NULL DEFAULT 0,
  note          text,
  created_by    uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ppc_output_plan ON public.ppc_output(plan_id);
CREATE INDEX IF NOT EXISTS idx_ppc_output_date ON public.ppc_output(plant_id, log_date);

-- ── RLS: plant-scoped + unit-isolated (same convention as tooling module) ─
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ppc_stages','ppc_parts','ppc_operators','ppc_month_plan','ppc_plan','ppc_output']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t||'_sel', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t||'_ins', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t||'_upd', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t||'_del', t);
    EXECUTE format('DROP POLICY IF EXISTS unit_iso ON public.%I', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (plant_id = my_plant_id())', t||'_sel', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (plant_id = my_plant_id())', t||'_ins', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (plant_id = my_plant_id()) WITH CHECK (plant_id = my_plant_id())', t||'_upd', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (plant_id = my_plant_id())', t||'_del', t);
    EXECUTE format('CREATE POLICY unit_iso ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING (public.unit_visible(unit_id)) WITH CHECK (public.unit_visible(unit_id))', t);
    EXECUTE format('DROP TRIGGER IF EXISTS trg_set_unit ON public.%I', t);
    EXECUTE format('CREATE TRIGGER trg_set_unit BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_unit_from_active()', t);
  END LOOP;
END $$;

-- RBAC: grant the PPC module to every built-in role on existing plants.
INSERT INTO public.role_permissions (role_id, module_key, action)
SELECT pr.id, 'ppc', '*'
FROM public.plant_roles pr
WHERE pr.is_builtin
ON CONFLICT DO NOTHING;
