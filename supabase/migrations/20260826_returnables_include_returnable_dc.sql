-- v_returnables_open tracked only job-work lines, so a sales Returnable DC
-- (dc_out_returnable) never appeared in Documents > Returnables. Add a second
-- branch surfacing each item of a returnable DC as an open returnable line (party
-- name from the doc's vendor_name_raw, set for both customer and vendor RDCs). A
-- `source` column tags origin so the UI hides job-work-only actions (SLA) on RDCs.
CREATE OR REPLACE VIEW public.v_returnables_open AS
 SELECT jl.id, jl.plant_id, jl.doc_id, d.doc_number, d.doc_date AS sent_on,
    jl.vendor_id, v.name AS vendor_name, v.is_jobwork_vendor, jl.item_id,
    jl.stock_item_id, jl.item_name, jl.hsn, jl.uom, jl.process, jl.qty_sent,
    COALESCE(jl.qty_received_back, 0::numeric) AS qty_received_back,
    GREATEST(jl.qty_sent - COALESCE(jl.qty_received_back, 0::numeric), 0::numeric) AS qty_pending,
    jl.status, jl.sla_days, jl.expected_return_date, jl.last_received_at,
    jl.created_at AS sent_at,
    EXTRACT(day FROM now() - jl.created_at)::integer AS days_pending,
        CASE WHEN jl.expected_return_date IS NULL THEN NULL::integer
             ELSE EXTRACT(day FROM now() - jl.expected_return_date::timestamp without time zone::timestamp with time zone)::integer END AS days_overdue,
        CASE WHEN jl.expected_return_date IS NOT NULL AND jl.expected_return_date < CURRENT_DATE THEN true ELSE false END AS sla_breached,
    jl.unit_id, 'jobwork'::text AS source
   FROM mcp_logistics_jobwork_lines jl
     LEFT JOIN mcp_logistics_vendors v ON v.id = jl.vendor_id
     LEFT JOIN mcp_logistics_documents d ON d.id = jl.doc_id
  WHERE jl.status = ANY (ARRAY['open'::text, 'partial'::text])
UNION ALL
 SELECT md5(d.id::text || '#' || t.ord::text)::uuid AS id, d.plant_id, d.id AS doc_id,
    d.doc_number, d.doc_date AS sent_on, d.vendor_id,
    COALESCE(v.name, d.vendor_name_raw) AS vendor_name,
    COALESCE(v.is_jobwork_vendor, false) AS is_jobwork_vendor, NULL::uuid AS item_id,
    NULLIF(t.it->>'stock_item_id','')::uuid AS stock_item_id,
    COALESCE(t.it->>'name', t.it->>'item_name') AS item_name, t.it->>'hsn' AS hsn,
    t.it->>'uom' AS uom, NULL::text AS process,
    COALESCE(NULLIF(t.it->>'qty','')::numeric, 0::numeric)::numeric(14,3) AS qty_sent,
    0::numeric AS qty_received_back,
    COALESCE(NULLIF(t.it->>'qty','')::numeric, 0::numeric) AS qty_pending,
    'open'::text AS status, NULL::integer AS sla_days, NULL::date AS expected_return_date,
    NULL::timestamp with time zone AS last_received_at, d.created_at AS sent_at,
    EXTRACT(day FROM now() - d.created_at)::integer AS days_pending,
    NULL::integer AS days_overdue, false AS sla_breached, d.unit_id,
    'returnable_dc'::text AS source
   FROM mcp_logistics_documents d
     LEFT JOIN mcp_logistics_vendors v ON v.id = d.vendor_id,
     LATERAL jsonb_array_elements(COALESCE(d.items, '[]'::jsonb)) WITH ORDINALITY AS t(it, ord)
  WHERE d.doc_type = 'dc_out_returnable'
    AND COALESCE(NULLIF(t.it->>'qty','')::numeric, 0::numeric) > 0;
