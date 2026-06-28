-- Per-unit data isolation — SCHEMA + BACK-FILL (additive; no behavior change).
-- Add unit_id to every plant-scoped DATA table that lacks it. Back-fill: derive
-- from natural parents where possible (all plants); fill Krishnas Fittings' rows
-- to Unit 2 (everything there was created under Unit 2). Other multi-unit plants
-- keep NULL (= shared/visible) where no parent unit exists, so no data is hidden.

-- 2a) Operational tables (explicit, with parent derivations).
ALTER TABLE public.actions                     ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id);
ALTER TABLE public.mcp_quality_ncrs            ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id);
ALTER TABLE public.mcp_maintenance_breakdowns  ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id);
ALTER TABLE public.mcp_expenses                ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id);
ALTER TABLE public.mcp_petty_cash_txns         ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id);
ALTER TABLE public.mcp_projects                ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id);
ALTER TABLE public.mcp_mom_meetings            ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id);
ALTER TABLE public.mcp_customer_complaints     ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id);
ALTER TABLE public.mcp_quotations              ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id);
ALTER TABLE public.mcp_cut_plans               ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id);
ALTER TABLE public.mcp_tpm_runs                ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id);
ALTER TABLE public.mcp_npd_projects            ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id);
ALTER TABLE public.mcp_stocks_transactions     ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units(id);

UPDATE public.mcp_maintenance_breakdowns x SET unit_id = m.unit_id FROM public.machines m            WHERE x.machine_id = m.id AND x.unit_id IS NULL AND m.unit_id IS NOT NULL;
UPDATE public.mcp_tpm_runs               x SET unit_id = m.unit_id FROM public.machines m            WHERE x.machine_id = m.id AND x.unit_id IS NULL AND m.unit_id IS NOT NULL;
UPDATE public.mcp_petty_cash_txns        x SET unit_id = b.unit_id FROM public.mcp_petty_cash_books b WHERE x.book_id = b.id    AND x.unit_id IS NULL AND b.unit_id IS NOT NULL;
UPDATE public.mcp_stocks_transactions    x SET unit_id = i.unit_id FROM public.mcp_stocks_items i     WHERE x.item_id = i.id    AND x.unit_id IS NULL AND i.unit_id IS NOT NULL;
UPDATE public.mcp_quality_ncrs           x SET unit_id = p.unit_id FROM public.mcp_pdc_parts p        WHERE x.part_id = p.id    AND x.unit_id IS NULL AND p.unit_id IS NOT NULL;
UPDATE public.mcp_customer_complaints    x SET unit_id = p.unit_id FROM public.mcp_pdc_parts p        WHERE x.part_id = p.id    AND x.unit_id IS NULL AND p.unit_id IS NOT NULL;

-- 2b) Every remaining plant-scoped DATA table (incl. IATF), skipping config +
--     genuinely-shared tables. Then Krishnas -> Unit 2 across all of them.
DO $$
DECLARE
  r record; v_k uuid; v_u2 uuid := '10fe9f13-5b30-4943-ac8c-f68f145aeef1';
  blocklist text[] := ARRAY[
    'users','units','user_invites','plant_roles','role_permissions','user_plant_roles',
    'password_reset_requests','push_subscriptions','notification_queue','audit_log','activity_log',
    'ai_usage','ai_audit_runs','voice_usage_daily','mcp_payroll_config','mcp_plant_holidays',
    'mcp_record_templates','report_doc_numbers','report_doc_number_history','mcp_logistics_doc_counters',
    'pulse_cadences','pulse_tasks','mcp_ocr_usage','plants','interunit_transfers','interunit_transfer_lines',
    'mcp_supplier_alert_log','mcp_logistics_vendors','mcp_sched_customers','mcp_sched_customer_aliases',
    'customer_part_aliases','user_unit_access','departments','shifts'];
BEGIN
  SELECT id INTO v_k FROM public.plants WHERE name ILIKE 'krishna%' LIMIT 1;
  FOR r IN
    SELECT c.relname AS t FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind='r'
      AND EXISTS (SELECT 1 FROM information_schema.columns col WHERE col.table_schema='public' AND col.table_name=c.relname AND col.column_name='plant_id')
      AND NOT EXISTS (SELECT 1 FROM information_schema.columns col WHERE col.table_schema='public' AND col.table_name=c.relname AND col.column_name='unit_id')
      AND c.relname <> ALL(blocklist)
  LOOP
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN unit_id uuid REFERENCES public.units(id)', r.t);
    IF v_k IS NOT NULL THEN
      EXECUTE format('UPDATE public.%I SET unit_id = $1 WHERE plant_id = $2 AND unit_id IS NULL', r.t) USING v_u2, v_k;
    END IF;
  END LOOP;
END $$;
