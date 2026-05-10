// extract-document/index.ts  — v15 (plant-aware extraction)
// Loglinkr extraction worker. Reads a row from mcp_logistics_extraction_queue,
// fetches plant context (units + vendors + stock items), calls Claude vision with
// a strongly-typed prompt that returns:
//   • direction: 'in' | 'out' | 'interunit_in' | 'interunit_out' | 'jobwork_out' | 'jobwork_in'
//   • doc_type, vendor_match_id, is_returnable, confidence, flags[]
// Writes structured output to mcp_logistics_documents and the cascade triggers
// pick it up from there (auto-GRN for inward, auto-supplies for outward, etc).
//
// Backwards compatible: client may pass {queue_id} only.  Plant context is
// resolved from the queue row's plant_id using service role.
//
// Versioned so re-deploys are visible in get_logs / debug_payload.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-4-20250514";
const WORKER_VERSION = "v15.1";

// Tunables
const VENDOR_CONTEXT_LIMIT = 60;   // top-N vendors fed to the model
const ITEM_CONTEXT_LIMIT   = 80;   // top-N stock items fed to the model

interface QueueRow {
  id: string;
  plant_id: string;
  message_id: string | null;
  group_id: string | null;
  image_url: string;
  attempts: number;
}

interface ExtractionPayload {
  is_document: boolean;
  classification: "document" | "non_document";
  direction?: "in" | "out" | "interunit_in" | "interunit_out" | "jobwork_out" | "jobwork_in" | "unknown";
  doc_type?: string;
  doc_number?: string | null;
  doc_date?: string | null;
  due_date?: string | null;
  vendor_name?: string | null;       // raw OCR string
  vendor_gstin?: string | null;
  vendor_match_id?: string | null;   // resolved against known vendors (uuid) or null
  buyer_name?: string | null;
  buyer_gstin?: string | null;
  from_unit_name?: string | null;    // for interunit
  to_unit_name?: string | null;      // for interunit
  is_returnable?: boolean;
  jobwork_process?: string | null;   // for jobwork_out: "plating", "heat treatment", etc.
  taxable_value?: number | null;
  tax_amount?: number | null;
  total_value?: number | null;
  items?: Array<Record<string, unknown>>;
  validation_note?: string;
  confidence?: "high" | "medium" | "low";
  flags?: string[];
}

const VALID_DOC_TYPES = new Set([
  "invoice_in", "invoice_out", "dc_in", "dc_out",
  "job_work_dc_out", "job_work_dc_in", "bill", "quote", "po",
  "other", "interunit_dc_out", "interunit_dc_in",
]);

// direction → doc_type when extractor returns direction but no doc_type
const DIRECTION_TO_DOC_TYPE: Record<string, string> = {
  "in":             "dc_in",          // refined below if invoice/bill/po seen
  "out":            "dc_out",
  "interunit_in":   "interunit_dc_in",
  "interunit_out":  "interunit_dc_out",
  "jobwork_out":    "job_work_dc_out",
  "jobwork_in":     "job_work_dc_in",
};

function buildPrompt(ctx: {
  plantName: string;
  plantLegalName: string | null;
  plantGstin: string | null;
  units: Array<{ id: string; name: string; address: string | null }>;
  vendors: Array<{ id: string; name: string; legal_name: string | null; gstin: string | null; is_jobwork_vendor: boolean }>;
  stockItems: Array<{ id: string; code: string; name: string }>;
}): string {
  const unitLines = ctx.units.length
    ? ctx.units.map((u, i) => `  ${i + 1}. ${u.name}${u.address ? ` — ${u.address}` : ""}`).join("\n")
    : "  (none configured)";

  const vendorLines = ctx.vendors.length
    ? ctx.vendors.map(v =>
        `  - id=${v.id} | name="${v.name}"${v.legal_name && v.legal_name !== v.name ? ` (legal: "${v.legal_name}")` : ""}${v.gstin ? ` | GSTIN ${v.gstin}` : ""}${v.is_jobwork_vendor ? " | JOB-WORK" : ""}`
      ).join("\n")
    : "  (none yet — first time vendor will be created on confirm)";

  const itemLines = ctx.stockItems.length
    ? ctx.stockItems.map(i => `  - ${i.code}: ${i.name}`).join("\n")
    : "  (none)";

  return `You are an extraction worker for Loglinkr — an audit-ready ERP for an Indian SME manufacturer. You will read ONE photo or scan of a logistics document (delivery challan / invoice / PO / bill / job-work DC) and return ONE strict JSON object.

═══════════════════════════════════════════════════════════
PLANT IDENTITY (this is "us" — figure out which side of the doc we are on)
═══════════════════════════════════════════════════════════
Name:        ${ctx.plantName}
Legal name:  ${ctx.plantLegalName ?? "(same)"}
GSTIN:       ${ctx.plantGstin ?? "(unknown)"}

UNITS we own (any of these as either party = "us", and party-to-party between two of these = INTERUNIT):
${unitLines}

═══════════════════════════════════════════════════════════
KNOWN VENDORS / CUSTOMERS (try to match the counterparty to one of these)
═══════════════════════════════════════════════════════════
${vendorLines}

═══════════════════════════════════════════════════════════
KNOWN STOCK ITEMS (use these spellings if a line item visibly matches one)
═══════════════════════════════════════════════════════════
${itemLines}

═══════════════════════════════════════════════════════════
DIRECTION RULES (most important)
═══════════════════════════════════════════════════════════
Determine which side of the document our plant is on:

• If the SELLER / CONSIGNOR / "From" is us (matches plant GSTIN, plant name, or one of our units) AND the BUYER / CONSIGNEE / "To" is one of our OTHER units →
    direction = "interunit_out"
    doc_type = "interunit_dc_out"
    Set from_unit_name and to_unit_name to the matching unit names.

• If the SELLER is one of our units AND the BUYER is us at a different unit →
    direction = "interunit_in"
    doc_type = "interunit_dc_in"

• If the SELLER is us AND the BUYER is a real external vendor/customer →
    direction = "out"
    doc_type = "invoice_out" if it's a tax invoice with rates/amounts
    doc_type = "dc_out" if it's a plain delivery challan (no rate/amount)

• If the BUYER is us AND the SELLER is an external vendor →
    direction = "in"
    doc_type = "invoice_in" or "dc_in" by the same rule
    BUT: if the document mentions "Job Work", "Sub-contract", "Process", "For Plating",
         "Heat Treatment", "Annealing", "Polishing", "Coating", "Grinding", "Machining",
         "Returnable", "Returnable basis", "Returnable for processing" → this is a return
         coming back from a job-work vendor (we sent material out, they processed it,
         now it's back). Set:
            direction = "jobwork_in"
            doc_type = "job_work_dc_in"
            jobwork_process = the named process

• If the SELLER is us AND the doc mentions any of the job-work / processing keywords above
  AND the BUYER is a vendor (not a final customer) →
    direction = "jobwork_out"
    doc_type = "job_work_dc_out"
    is_returnable = true
    jobwork_process = the named process

• If you can't tell with confidence → direction = "unknown", doc_type = "other".

═══════════════════════════════════════════════════════════
COUNTERPARTY MATCHING
═══════════════════════════════════════════════════════════
After picking direction, identify the counterparty (the OTHER side, not us):
  vendor_name      = exact OCR'd name as printed
  vendor_gstin     = OCR'd GSTIN of the counterparty
  vendor_match_id  = if the counterparty matches a row in KNOWN VENDORS by name OR
                     GSTIN (case-insensitive, fuzzy on name), return that row's id.
                     Else null. Do not guess. Match GSTIN > legal_name > name.

═══════════════════════════════════════════════════════════
LINE ITEMS — STRICT
═══════════════════════════════════════════════════════════
items[] must contain ONLY real product/material rows from the line-item table.
DO NOT include any of these as items (they look like rows but are not):
  ✗ "Total", "Sub-total", "Grand Total", "Amount in Words"
  ✗ "Received the above goods in good condition" / signature blocks
  ✗ Tax summary rows (CGST, SGST, IGST, Round-off)
  ✗ Footer disclaimers, terms & conditions
  ✗ Empty rows, "—", or ditto-mark continuations

For each real line, populate:
  name      — item description as printed
  hsn       — HSN/SAC code if visible, else null
  qty       — number, never null on a real line
  uom       — unit of measure (NOS, KGS, MT, PCS, SET…), null if absent
  rate      — unit rate, null on a pure DC with no prices
  amount    — qty × rate, null on a pure DC
  process   — for jobwork rows: which operation (plating, heat-treat…); else ""

═══════════════════════════════════════════════════════════
ARITHMETIC SELF-CHECK
═══════════════════════════════════════════════════════════
After listing items, verify:
  sum(items[].amount) ≈ taxable_value   (tolerate ±1 for round-off)
  total_value ≈ taxable_value + tax_amount
If either check fails, add "arithmetic_mismatch" to flags[] and explain in validation_note.

═══════════════════════════════════════════════════════════
DATES
═══════════════════════════════════════════════════════════
Always return ISO YYYY-MM-DD. Indian docs often use DD/MM/YY or DD-MMM-YY:
  "8-May-26"  → 2026-05-08
  "05/05/24"  → 2024-05-05  (DD/MM/YY assumed unless context proves otherwise)
If the year is two digits and ambiguous (>= today + 1 year), prefer the past century only if a 4-digit year appears elsewhere on the doc indicating earlier years. Otherwise default to current decade.
If the date is illegible / handwritten / inferred → add "date_inferred" to flags[].

═══════════════════════════════════════════════════════════
CONFIDENCE
═══════════════════════════════════════════════════════════
confidence = "high"   if image is sharp, all key fields visible, arithmetic balances
confidence = "medium" if minor ambiguity (one field unclear, arithmetic off by <2%)
confidence = "low"    if image is blurry / handwritten / multiple fields missing

═══════════════════════════════════════════════════════════
OUTPUT FORMAT — RETURN ONLY THIS JSON, NO PROSE, NO MARKDOWN FENCES
═══════════════════════════════════════════════════════════
{
  "is_document": boolean,
  "classification": "document" | "non_document",
  "direction": "in" | "out" | "interunit_in" | "interunit_out" | "jobwork_out" | "jobwork_in" | "unknown",
  "doc_type": "<one of: invoice_in, invoice_out, dc_in, dc_out, job_work_dc_out, job_work_dc_in, interunit_dc_out, interunit_dc_in, bill, quote, po, other>",
  "doc_number": string | null,
  "doc_date": "YYYY-MM-DD" | null,
  "due_date": "YYYY-MM-DD" | null,
  "vendor_name": string | null,
  "vendor_gstin": string | null,
  "vendor_match_id": string | null,
  "buyer_name": string | null,
  "buyer_gstin": string | null,
  "from_unit_name": string | null,
  "to_unit_name": string | null,
  "is_returnable": boolean,
  "jobwork_process": string | null,
  "taxable_value": number | null,
  "tax_amount": number | null,
  "total_value": number | null,
  "items": [
    {"name": "...", "hsn": null, "qty": 0, "uom": null, "rate": null, "amount": null, "process": ""}
  ],
  "validation_note": "what you cross-checked, any concerns",
  "confidence": "high" | "medium" | "low",
  "flags": ["arithmetic_mismatch", "date_inferred", "low_quality_image", "vendor_unrecognized", "junk_filtered"]
}

If the image is not a logistics document at all (selfie, screenshot, random photo):
  is_document = false, classification = "non_document", leave other fields null/[].`;
}

function safeJsonParse(raw: string): unknown {
  let cleaned = raw.trim();
  const fenceMatch = cleaned.match(/^```(?:json)?\s*\n?([\s\S]*?)\n?```$/);
  if (fenceMatch) cleaned = fenceMatch[1].trim();
  const firstBrace = cleaned.indexOf("{");
  const firstBracket = cleaned.indexOf("[");
  const start = firstBrace === -1 ? firstBracket
              : firstBracket === -1 ? firstBrace
              : Math.min(firstBrace, firstBracket);
  if (start > 0) cleaned = cleaned.slice(start);
  const lastBrace = cleaned.lastIndexOf("}");
  const lastBracket = cleaned.lastIndexOf("]");
  const end = Math.max(lastBrace, lastBracket);
  if (end > 0 && end < cleaned.length - 1) cleaned = cleaned.slice(0, end + 1);
  return JSON.parse(cleaned);
}

// Resolve doc_type from the model's direction + doc_type, with fallbacks.
function resolveDocType(parsed: ExtractionPayload): string {
  // 1. If model returned a valid doc_type, trust it.
  if (parsed.doc_type && VALID_DOC_TYPES.has(parsed.doc_type)) {
    return parsed.doc_type;
  }
  // 2. Else derive from direction.
  if (parsed.direction && DIRECTION_TO_DOC_TYPE[parsed.direction]) {
    let dt = DIRECTION_TO_DOC_TYPE[parsed.direction];
    // refine "in"/"out" → invoice if rates/amount were extracted
    if ((dt === "dc_in" || dt === "dc_out") && (parsed.tax_amount || parsed.taxable_value)) {
      dt = dt === "dc_in" ? "invoice_in" : "invoice_out";
    }
    return dt;
  }
  return "other";
}

async function fetchPlantContext(
  supabase: ReturnType<typeof createClient>,
  plantId: string,
) {
  // plant
  const { data: plant } = await supabase
    .from("plants")
    .select("id, name, legal_name, gstin")
    .eq("id", plantId)
    .maybeSingle();

  // units
  const { data: units } = await supabase
    .from("units")
    .select("id, name, address")
    .eq("plant_id", plantId)
    .order("name");

  // vendors — prefer recently used (we'd need a usage signal; fall back to created_at)
  const { data: vendors } = await supabase
    .from("mcp_logistics_vendors")
    .select("id, name, legal_name, gstin, is_jobwork_vendor")
    .eq("plant_id", plantId)
    .order("updated_at", { ascending: false })
    .limit(VENDOR_CONTEXT_LIMIT);

  // stock items — use most-recent for context
  const { data: items } = await supabase
    .from("mcp_stocks_items")
    .select("id, code, name")
    .eq("plant_id", plantId)
    .order("updated_at", { ascending: false })
    .limit(ITEM_CONTEXT_LIMIT);

  return {
    plantName:      plant?.name ?? "(unknown)",
    plantLegalName: plant?.legal_name ?? null,
    plantGstin:     plant?.gstin ?? null,
    units:          units ?? [],
    vendors:        vendors ?? [],
    stockItems:     items ?? [],
  };
}

async function processQueueRow(
  supabase: ReturnType<typeof createClient>,
  row: QueueRow,
) {
  const startedAt = Date.now();
  const newAttempts = row.attempts + 1;

  await supabase
    .from("mcp_logistics_extraction_queue")
    .update({
      status: "processing",
      attempts: newAttempts,
      last_attempted_at: new Date().toISOString(),
    })
    .eq("id", row.id);

  let rawResponse: string | null = null;
  let stage = "init";

  try {
    stage = "fetch_context";
    const ctx = await fetchPlantContext(supabase, row.plant_id);
    const prompt = buildPrompt(ctx);

    stage = "fetch_image";
    const imgRes = await fetch(row.image_url);
    if (!imgRes.ok) throw new Error(`Image fetch ${imgRes.status}`);
    const imgBuf = await imgRes.arrayBuffer();
    const bytes = new Uint8Array(imgBuf);
    let binary = "";
    const chunkSize = 32768;
    for (let i = 0; i < bytes.length; i += chunkSize) {
      binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
    }
    const imgB64 = btoa(binary);
    let mediaType = imgRes.headers.get("content-type") || "image/jpeg";
    if (mediaType.includes(";")) mediaType = mediaType.split(";")[0].trim();
    if (!["image/jpeg", "image/png", "image/webp", "image/gif"].includes(mediaType)) {
      mediaType = "image/jpeg";
    }

    stage = "vision_call";
    const visionRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 3072,
        messages: [{
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: mediaType, data: imgB64 } },
            { type: "text", text: prompt },
          ],
        }],
      }),
    });

    if (!visionRes.ok) {
      throw new Error(`Vision API ${visionRes.status}: ${(await visionRes.text()).slice(0, 500)}`);
    }

    const visionData = await visionRes.json();
    rawResponse = visionData.content
      ?.filter((b: { type: string }) => b.type === "text")
      ?.map((b: { text: string }) => b.text)
      ?.join("\n") ?? "";

    stage = "json_parse";
    const parsed = safeJsonParse(rawResponse) as ExtractionPayload;

    stage = "validate";
    if (typeof parsed.is_document !== "boolean") {
      throw new Error("Missing is_document boolean in extraction");
    }

    if (!parsed.is_document) {
      await supabase
        .from("mcp_logistics_extraction_queue")
        .update({
          status: "skipped",
          classification: "non_document",
          processed_at: new Date().toISOString(),
          extraction_ms: Date.now() - startedAt,
          error_message: null,
          raw_response: null,
          debug_payload: { worker_version: WORKER_VERSION },
        })
        .eq("id", row.id);
      return { ok: true, queue_id: row.id, skipped: true };
    }

    const docType = resolveDocType(parsed);

    // Resolve vendor_id: trust the model's vendor_match_id only if it's a real uuid in our list.
    let resolvedVendorId: string | null = null;
    if (parsed.vendor_match_id && /^[0-9a-f-]{36}$/i.test(parsed.vendor_match_id)) {
      const { data: v } = await supabase
        .from("mcp_logistics_vendors")
        .select("id")
        .eq("id", parsed.vendor_match_id)
        .eq("plant_id", row.plant_id)
        .maybeSingle();
      if (v) resolvedVendorId = v.id;
    }

    // Build raw_extraction blob (everything the model returned + our metadata)
    const rawExtraction = {
      ...parsed,
      _worker_version: WORKER_VERSION,
      _model: MODEL,
      _resolved_doc_type: docType,
      _resolved_vendor_id: resolvedVendorId,
    };

    stage = "persist";
    const { data: doc, error: docErr } = await supabase
      .from("mcp_logistics_documents")
      .insert({
        plant_id: row.plant_id,
        doc_type: docType,
        doc_number: parsed.doc_number ?? null,
        doc_date: parsed.doc_date ?? null,
        due_date: parsed.due_date ?? null,
        vendor_id: resolvedVendorId,
        vendor_name_raw: parsed.vendor_name ?? null,
        vendor_gstin_raw: parsed.vendor_gstin ?? null,
        taxable_value: parsed.taxable_value ?? null,
        tax_amount: parsed.tax_amount ?? null,
        total_value: parsed.total_value ?? null,
        items: parsed.items ?? [],
        raw_extraction: rawExtraction,
        validation_note: parsed.validation_note ?? null,
        source_message_id: row.message_id,
        source_image_url: row.image_url,
        extracted_by_ai: true,
        extraction_status: "completed",
        status: "pending",
      })
      .select("id")
      .single();
    if (docErr) throw docErr;

    // Keep raw_response on disk only for medium/low confidence — saves bytes on the
    // happy path, preserves debugging info when something looks off.
    const keepRawForDebug = parsed.confidence !== "high"
                         || (parsed.flags && parsed.flags.length > 0);

    await supabase
      .from("mcp_logistics_extraction_queue")
      .update({
        status: "completed",
        result_doc_id: doc.id,
        classification: "document",
        processed_at: new Date().toISOString(),
        extraction_ms: Date.now() - startedAt,
        error_message: null,
        raw_response: keepRawForDebug ? rawResponse?.slice(0, 8192) ?? null : null,
        debug_payload: {
          worker_version: WORKER_VERSION,
          model: MODEL,
          confidence: parsed.confidence ?? null,
          flags: parsed.flags ?? [],
          direction: parsed.direction ?? null,
          resolved_doc_type: docType,
          vendor_match_id: resolvedVendorId,
        },
      })
      .eq("id", row.id);

    return {
      ok: true,
      queue_id: row.id,
      doc_id: doc.id,
      doc_type: docType,
      direction: parsed.direction,
      confidence: parsed.confidence,
      flags: parsed.flags,
    };

  } catch (err) {
    const e = err as Error;

    await supabase
      .from("mcp_logistics_extraction_queue")
      .update({
        status: "failed",
        raw_response: rawResponse?.slice(0, 8192) ?? null,
        error_message: `${stage}: ${e.message}`.slice(0, 500),
        debug_payload: {
          stage,
          exception_type: e.name,
          exception_message: e.message,
          stack: e.stack?.slice(0, 2000),
          model_used: MODEL,
          attempt_number: newAttempts,
          worker_version: WORKER_VERSION,
        },
        processed_at: new Date().toISOString(),
        extraction_ms: Date.now() - startedAt,
      })
      .eq("id", row.id);

    return { ok: false, queue_id: row.id, error: `${stage}: ${e.message}` };
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
      },
    });
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_KEY);

  try {
    let body: { queue_id?: string; batch_size?: number; reextract_doc_id?: string } = {};
    try { body = await req.json(); } catch { /* empty body ok */ }

    let rows: QueueRow[];

    // Re-extract path: client passes an existing doc_id; we synthesise a queue row
    // pointing at the doc's source_image_url and process it again.
    if (body.reextract_doc_id) {
      const { data: srcDoc, error: srcErr } = await supabase
        .from("mcp_logistics_documents")
        .select("id, plant_id, source_message_id, source_image_url")
        .eq("id", body.reextract_doc_id)
        .maybeSingle();
      if (srcErr) throw srcErr;
      if (!srcDoc) throw new Error("reextract_doc_id not found");
      if (!srcDoc.source_image_url) throw new Error("source doc has no source_image_url");

      // Re-extracts get a fresh queue row decoupled from the original message — the
      // unique constraint on message_id only allows one queue row per chat message,
      // and we want to preserve the original extraction's audit trail untouched.
      // The new doc still carries source_image_url so the trace back is preserved.
      const { data: q, error: qErr } = await supabase
        .from("mcp_logistics_extraction_queue")
        .insert({
          plant_id: srcDoc.plant_id,
          message_id: null,
          group_id: null,
          image_url: srcDoc.source_image_url,
          status: "pending",
        })
        .select("id, plant_id, message_id, group_id, image_url, attempts")
        .single();
      if (qErr) throw qErr;
      rows = [q as QueueRow];
    } else if (body.queue_id) {
      const { data, error } = await supabase
        .from("mcp_logistics_extraction_queue")
        .select("id, plant_id, message_id, group_id, image_url, attempts")
        .eq("id", body.queue_id)
        .limit(1);
      if (error) throw error;
      rows = (data ?? []) as QueueRow[];
    } else {
      const limit = Math.min(body.batch_size ?? 5, 10);
      const { data, error } = await supabase
        .from("mcp_logistics_extraction_queue")
        .select("id, plant_id, message_id, group_id, image_url, attempts")
        .eq("status", "pending")
        .order("created_at", { ascending: true })
        .limit(limit);
      if (error) throw error;
      rows = (data ?? []) as QueueRow[];
    }

    const results = [];
    for (const row of rows) {
      results.push(await processQueueRow(supabase, row));
    }

    const success = results.length > 0 && results.every(r => r.ok);
    return new Response(
      JSON.stringify({ success, processed: results.length, results, worker_version: WORKER_VERSION }, null, 2),
      { headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } },
    );

  } catch (err) {
    const e = err as Error;
    return new Response(
      JSON.stringify({ success: false, error: e.message, stack: e.stack?.slice(0, 500) }),
      { status: 500, headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } },
    );
  }
});
