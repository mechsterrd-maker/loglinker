-- RLS for the new quality-rejection module tables. Mirrors mcp_pdc_rejection_types:
-- PERMISSIVE per-command policies scoped to the caller's plant, plus a RESTRICTIVE
-- unit_iso policy so unit isolation holds for everyone (owners narrow via unitScope).

-- mcp_quality_rejections
DROP POLICY IF EXISTS mcp_quality_rejections_sel ON public.mcp_quality_rejections;
DROP POLICY IF EXISTS mcp_quality_rejections_ins ON public.mcp_quality_rejections;
DROP POLICY IF EXISTS mcp_quality_rejections_upd ON public.mcp_quality_rejections;
DROP POLICY IF EXISTS mcp_quality_rejections_del ON public.mcp_quality_rejections;
DROP POLICY IF EXISTS unit_iso ON public.mcp_quality_rejections;
CREATE POLICY mcp_quality_rejections_sel ON public.mcp_quality_rejections FOR SELECT USING (plant_id = my_plant_id());
CREATE POLICY mcp_quality_rejections_ins ON public.mcp_quality_rejections FOR INSERT WITH CHECK (plant_id = my_plant_id());
CREATE POLICY mcp_quality_rejections_upd ON public.mcp_quality_rejections FOR UPDATE USING (plant_id = my_plant_id()) WITH CHECK (plant_id = my_plant_id());
CREATE POLICY mcp_quality_rejections_del ON public.mcp_quality_rejections FOR DELETE USING (plant_id = my_plant_id());
CREATE POLICY unit_iso ON public.mcp_quality_rejections AS RESTRICTIVE FOR ALL USING (unit_visible(unit_id)) WITH CHECK (unit_visible(unit_id));

-- mcp_quality_ppm_base
DROP POLICY IF EXISTS mcp_quality_ppm_base_sel ON public.mcp_quality_ppm_base;
DROP POLICY IF EXISTS mcp_quality_ppm_base_ins ON public.mcp_quality_ppm_base;
DROP POLICY IF EXISTS mcp_quality_ppm_base_upd ON public.mcp_quality_ppm_base;
DROP POLICY IF EXISTS mcp_quality_ppm_base_del ON public.mcp_quality_ppm_base;
DROP POLICY IF EXISTS unit_iso ON public.mcp_quality_ppm_base;
CREATE POLICY mcp_quality_ppm_base_sel ON public.mcp_quality_ppm_base FOR SELECT USING (plant_id = my_plant_id());
CREATE POLICY mcp_quality_ppm_base_ins ON public.mcp_quality_ppm_base FOR INSERT WITH CHECK (plant_id = my_plant_id());
CREATE POLICY mcp_quality_ppm_base_upd ON public.mcp_quality_ppm_base FOR UPDATE USING (plant_id = my_plant_id()) WITH CHECK (plant_id = my_plant_id());
CREATE POLICY mcp_quality_ppm_base_del ON public.mcp_quality_ppm_base FOR DELETE USING (plant_id = my_plant_id());
CREATE POLICY unit_iso ON public.mcp_quality_ppm_base AS RESTRICTIVE FOR ALL USING (unit_visible(unit_id)) WITH CHECK (unit_visible(unit_id));
