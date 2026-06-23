-- NPD Feasibility stage + CadNexa hooks.
--
-- Adds a feasibility milestone that sits between RFQ and Quote in the NPD
-- lifecycle. During feasibility a customer drawing can be auto-ballooned in
-- CadNexa and a 3D model can be loaded into the CadNexa 3D viewer; both files
-- are stored against the project, alongside a go/no-go decision.

ALTER TABLE public.mcp_npd_projects
  ADD COLUMN IF NOT EXISTS feasibility_target_date date,
  ADD COLUMN IF NOT EXISTS feasibility_actual_date date,
  ADD COLUMN IF NOT EXISTS feasibility_decision    text
    CHECK (feasibility_decision IN ('feasible','feasible_with_changes','not_feasible')),
  ADD COLUMN IF NOT EXISTS feasibility_notes       text,
  ADD COLUMN IF NOT EXISTS model_3d_url            text,
  ADD COLUMN IF NOT EXISTS balloon_drawing_url     text;

-- Extend the document-kind whitelist with the two CadNexa artefacts.
ALTER TABLE public.mcp_npd_documents DROP CONSTRAINT IF EXISTS mcp_npd_documents_kind_check;
ALTER TABLE public.mcp_npd_documents ADD CONSTRAINT mcp_npd_documents_kind_check
  CHECK (kind = ANY (ARRAY[
    'rfq','customer_drawing','quote','feasibility','tech_review','tool_design',
    'tool_quote','isir','control_plan','process_flow','msa','spc',
    'ppap_package','psw_signed','model_3d','balloon_drawing','other'
  ]));
