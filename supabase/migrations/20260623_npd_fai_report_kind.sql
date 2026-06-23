-- NPD feasibility: store CadNexa results back on the project.
-- balloon_drawing already exists (the ballooned 2D drawing); add fai_report
-- for the First Article Inspection report exported from CadNexa.
ALTER TABLE public.mcp_npd_documents DROP CONSTRAINT IF EXISTS mcp_npd_documents_kind_check;
ALTER TABLE public.mcp_npd_documents ADD CONSTRAINT mcp_npd_documents_kind_check
  CHECK (kind = ANY (ARRAY[
    'rfq','customer_drawing','quote','feasibility','tech_review','tool_design',
    'tool_quote','isir','control_plan','process_flow','msa','spc',
    'ppap_package','psw_signed','model_3d','balloon_drawing','fai_report','other'
  ]));
