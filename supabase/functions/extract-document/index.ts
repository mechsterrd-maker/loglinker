// extract-document/index.ts — v21 (hardened OCR with Indian-comma + server arithmetic check)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { Image } from "https://deno.land/x/imagescript@1.2.17/mod.ts";
import { buildPrompt } from "./prompt.ts";

const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-4-20250514";
const WORKER_VERSION = "v21";
const VENDOR_CONTEXT_LIMIT = 60;
const ITEM_CONTEXT_LIMIT   = 80;

interface QueueRow { id: string; plant_id: string; message_id: string | null; group_id: string | null; image_url: string; attempts: number; }
interface ExtractionPayload {
  is_document: boolean; classification: "document" | "non_document";
  seller_name?: string | null; seller_gstin?: string | null;
  buyer_name?: string | null; buyer_gstin?: string | null;
  seller_is_us?: boolean | null; buyer_is_us?: boolean | null;
  direction?: "in" | "out" | "interunit_in" | "interunit_out" | "jobwork_out" | "jobwork_in" | "unknown";
  doc_type?: string; doc_number?: string | null; doc_date?: string | null; due_date?: string | null;
  vendor_name?: string | null; vendor_gstin?: string | null; vendor_match_id?: string | null;
  from_unit_name?: string | null; to_unit_name?: string | null;
  is_returnable?: boolean; jobwork_process?: string | null;
  taxable_value?: number | null; tax_amount?: number | null; total_value?: number | null;
  items?: Array<Record<string, unknown>>;
  validation_note?: string; confidence?: "high" | "medium" | "low"; flags?: string[];
}

const VALID_DOC_TYPES = new Set(["invoice_in","invoice_out","dc_in","dc_out","job_work_dc_out","job_work_dc_in","bill","quote","po","other","interunit_dc_out","interunit_dc_in"]);
const DIRECTION_TO_DOC_TYPE: Record<string,string> = { "in":"dc_in","out":"dc_out","interunit_in":"interunit_dc_in","interunit_out":"interunit_dc_out","jobwork_out":"job_work_dc_out","jobwork_in":"job_work_dc_in" };

const ROTATION_PROMPT = `A document was photographed and may be rotated. To make text read upright, how many degrees CLOCKWISE should the photo be rotated? Answer with EXACTLY one number from: 0, 90, 180, 270. No words, no punctuation.`;

async function detectRotationDeg(imgB64: string, mediaType: string): Promise<number> {
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({ model: MODEL, max_tokens: 16, messages: [{ role: "user", content: [
        { type: "image", source: { type: "base64", media_type: mediaType, data: imgB64 } },
        { type: "text", text: ROTATION_PROMPT },
      ] }] }),
    });
    if (!res.ok) return 0;
    const data = await res.json();
    const text = (data.content?.filter((b: { type: string }) => b.type === "text")?.map((b: { text: string }) => b.text)?.join("") ?? "").trim();
    const m = text.match(/\b(0|90|180|270)\b/);
    const deg = m ? parseInt(m[1], 10) : 0;
    return [0,90,180,270].includes(deg) ? deg : 0;
  } catch { return 0; }
}

async function rotateImageBytes(bytes: Uint8Array, deg: number): Promise<{ bytes: Uint8Array; mediaType: string } | null> {
  if (deg === 0) return null;
  try {
    const img = await Image.decode(bytes);
    img.rotate(deg);
    const out = await img.encodeJPEG(95);
    return { bytes: out, mediaType: "image/jpeg" };
  } catch { return null; }
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 32768;
  for (let i = 0; i < bytes.length; i += chunkSize) binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  return btoa(binary);
}

function deriveHiresUrl(url: string): string {
  const m = url.match(/^(.+)(\.[a-zA-Z0-9]+)(\?.*)?$/);
  if (!m) return url + ".orig";
  return m[1] + ".orig" + m[2] + (m[3] ?? "");
}

function shouldEscalateToHires(parsed: ExtractionPayload): boolean {
  if (parsed.confidence === "low") return true;
  const flags = parsed.flags ?? [];
  const recoverableFlags = new Set(["doc_number_unreadable","date_unreadable","vendor_name_illegible","low_quality_image","arithmetic_mismatch"]);
  if (flags.some(f => recoverableFlags.has(f))) return true;
  if (parsed.is_document) {
    let nullCount = 0;
    if (!parsed.doc_number) nullCount++;
    if (!parsed.doc_date) nullCount++;
    if (!parsed.vendor_name) nullCount++;
    if (!parsed.items || parsed.items.length === 0) nullCount++;
    if (nullCount >= 3) return true;
  }
  return false;
}

function safeJsonParse(raw: string): unknown {
  let cleaned = raw.trim();
  const fenceMatch = cleaned.match(/^```(?:json)?\s*\n?([\s\S]*?)\n?```$/);
  if (fenceMatch) cleaned = fenceMatch[1].trim();
  const firstBrace = cleaned.indexOf("{");
  const firstBracket = cleaned.indexOf("[");
  const start = firstBrace === -1 ? firstBracket : firstBracket === -1 ? firstBrace : Math.min(firstBrace, firstBracket);
  if (start > 0) cleaned = cleaned.slice(start);
  const lastBrace = cleaned.lastIndexOf("}");
  const lastBracket = cleaned.lastIndexOf("]");
  const end = Math.max(lastBrace, lastBracket);
  if (end > 0 && end < cleaned.length - 1) cleaned = cleaned.slice(0, end + 1);
  return JSON.parse(cleaned);
}

function normalizeName(s: string | null | undefined): string {
  return (s ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function nameMatchesPlant(candidate: string | null | undefined, ctx: { plantName: string; plantLegalName: string | null; units: Array<{ name: string }> }): boolean {
  const c = normalizeName(candidate);
  if (!c) return false;
  const targets = [normalizeName(ctx.plantName), normalizeName(ctx.plantLegalName ?? ""), ...ctx.units.map(u => normalizeName(u.name))].filter(Boolean);
  for (const t of targets) {
    if (!t) continue;
    if (c === t) return true;
    if (c.length >= 6 && t.length >= 6 && (c.includes(t) || t.includes(c))) return true;
  }
  return false;
}

function gstinMatchesPlant(candidate: string | null | undefined, ctx: { plantGstin: string | null }): boolean {
  if (!candidate || !ctx.plantGstin) return false;
  return candidate.replace(/\s+/g, "").toUpperCase() === ctx.plantGstin.replace(/\s+/g, "").toUpperCase();
}

interface DirectionOverride { direction: ExtractionPayload["direction"]; reason: string; overridden: boolean; computed_seller_is_us: boolean; computed_buyer_is_us: boolean; }

function deriveDirection(parsed: ExtractionPayload, ctx: { plantName: string; plantLegalName: string | null; plantGstin: string | null; units: Array<{ name: string }> }): DirectionOverride {
  const sellerByGstin = gstinMatchesPlant(parsed.seller_gstin, ctx);
  const buyerByGstin  = gstinMatchesPlant(parsed.buyer_gstin, ctx);
  const sellerByName  = nameMatchesPlant(parsed.seller_name, ctx);
  const buyerByName   = nameMatchesPlant(parsed.buyer_name, ctx);
  let sellerIsUs: boolean | null = null, buyerIsUs: boolean | null = null;
  if (parsed.seller_gstin) sellerIsUs = sellerByGstin;
  else if (parsed.seller_name) sellerIsUs = sellerByName;
  if (parsed.buyer_gstin) buyerIsUs = buyerByGstin;
  else if (parsed.buyer_name) buyerIsUs = buyerByName;
  if (sellerIsUs === null && buyerIsUs === null) {
    return { direction: parsed.direction ?? "unknown", reason: "names insufficient", overridden: false, computed_seller_is_us: false, computed_buyer_is_us: false };
  }
  let computedDirection: ExtractionPayload["direction"];
  if (buyerIsUs === true && sellerIsUs !== true) computedDirection = "in";
  else if (sellerIsUs === true && buyerIsUs !== true) computedDirection = "out";
  else if (sellerIsUs === true && buyerIsUs === true) computedDirection = "interunit_out";
  else computedDirection = "unknown";
  if (parsed.direction === "jobwork_in" && computedDirection === "in") computedDirection = "jobwork_in";
  else if (parsed.direction === "jobwork_out" && computedDirection === "out") computedDirection = "jobwork_out";
  const overridden = parsed.direction !== computedDirection;
  return { direction: computedDirection, reason: overridden ? `override: seller_is_us=${sellerIsUs} buyer_is_us=${buyerIsUs} → ${computedDirection} (model said ${parsed.direction})` : `confirms: ${computedDirection}`, overridden, computed_seller_is_us: !!sellerIsUs, computed_buyer_is_us: !!buyerIsUs };
}

function resolveDocType(parsed: ExtractionPayload): string {
  if (parsed.doc_type && VALID_DOC_TYPES.has(parsed.doc_type)) return parsed.doc_type;
  if (parsed.direction && DIRECTION_TO_DOC_TYPE[parsed.direction]) {
    let dt = DIRECTION_TO_DOC_TYPE[parsed.direction];
    if ((dt === "dc_in" || dt === "dc_out") && (parsed.tax_amount || parsed.taxable_value)) dt = dt === "dc_in" ? "invoice_in" : "invoice_out";
    return dt;
  }
  return "other";
}

async function fetchPlantContext(supabase: ReturnType<typeof createClient>, plantId: string) {
  const { data: plant } = await supabase.from("plants").select("id, name, legal_name, gstin").eq("id", plantId).maybeSingle();
  const { data: units } = await supabase.from("units").select("id, name, address").eq("plant_id", plantId).order("name");
  const { data: vendors } = await supabase.from("mcp_logistics_vendors").select("id, name, legal_name, gstin, is_jobwork_vendor").eq("plant_id", plantId).order("updated_at", { ascending: false }).limit(VENDOR_CONTEXT_LIMIT);
  const { data: items } = await supabase.from("mcp_stocks_items").select("id, code, name").eq("plant_id", plantId).order("updated_at", { ascending: false }).limit(ITEM_CONTEXT_LIMIT);
  return { plantName: plant?.name ?? "(unknown)", plantLegalName: plant?.legal_name ?? null, plantGstin: plant?.gstin ?? null, units: units ?? [], vendors: vendors ?? [], stockItems: items ?? [] };
}

interface AttemptResult { parsed: ExtractionPayload; rawResponse: string; rotationLog: number[]; totalRotationDeg: number; imageUrl: string; bytesLen: number; }

async function attemptExtraction(url: string, prompt: string): Promise<AttemptResult> {
  const imgRes = await fetch(url);
  if (!imgRes.ok) throw new Error(`Image fetch ${imgRes.status} on ${url}`);
  const imgBuf = await imgRes.arrayBuffer();
  let bytes = new Uint8Array(imgBuf);
  let imgB64 = bytesToBase64(bytes);
  let mediaType = imgRes.headers.get("content-type") || "image/jpeg";
  if (mediaType.includes(";")) mediaType = mediaType.split(";")[0].trim();
  if (!["image/jpeg","image/png","image/webp","image/gif"].includes(mediaType)) mediaType = "image/jpeg";
  const rotationLog: number[] = [];
  {
    const deg = await detectRotationDeg(imgB64, mediaType);
    if (deg !== 0) {
      const rotated = await rotateImageBytes(bytes, deg);
      if (rotated) { bytes = rotated.bytes; mediaType = rotated.mediaType; imgB64 = bytesToBase64(bytes); rotationLog.push(deg); }
    }
  }
  const totalRotationDeg = rotationLog.reduce((s, d) => s + d, 0) % 360;
  const visionRes = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({ model: MODEL, max_tokens: 3072, messages: [{ role: "user", content: [
      { type: "image", source: { type: "base64", media_type: mediaType, data: imgB64 } },
      { type: "text", text: prompt },
    ] }] }),
  });
  if (!visionRes.ok) throw new Error(`Vision API ${visionRes.status}: ${(await visionRes.text()).slice(0, 500)}`);
  const visionData = await visionRes.json();
  const rawResponse = visionData.content?.filter((b: { type: string }) => b.type === "text")?.map((b: { text: string }) => b.text)?.join("\n") ?? "";
  const parsed = safeJsonParse(rawResponse) as ExtractionPayload;
  if (typeof parsed.is_document !== "boolean") throw new Error("Missing is_document boolean in extraction");
  return { parsed, rawResponse, rotationLog, totalRotationDeg, imageUrl: url, bytesLen: bytes.length };
}

async function hiresAvailable(hiresUrl: string): Promise<boolean> {
  try { const r = await fetch(hiresUrl, { method: "HEAD" }); return r.ok; } catch { return false; }
}

async function processQueueRow(supabase: ReturnType<typeof createClient>, row: QueueRow, forceHires = false) {
  const startedAt = Date.now();
  const newAttempts = row.attempts + 1;
  await supabase.from("mcp_logistics_extraction_queue").update({ status: "processing", attempts: newAttempts, last_attempted_at: new Date().toISOString() }).eq("id", row.id);
  let stage = "init";
  let lastRawResponse: string | null = null;
  try {
    stage = "fetch_context";
    const ctx = await fetchPlantContext(supabase, row.plant_id);
    const prompt = buildPrompt(ctx);
    stage = "extract_compressed";
    let attempt = await attemptExtraction(row.image_url, prompt);
    lastRawResponse = attempt.rawResponse;
    let escalated = false;
    if (attempt.parsed.is_document) {
      const hiresUrl = deriveHiresUrl(row.image_url);
      const wantsRetry = forceHires || shouldEscalateToHires(attempt.parsed);
      if (wantsRetry && hiresUrl !== row.image_url && await hiresAvailable(hiresUrl)) {
        stage = "extract_hires";
        try {
          const hiresAttempt = await attemptExtraction(hiresUrl, prompt);
          if (hiresAttempt.parsed.is_document) { attempt = hiresAttempt; lastRawResponse = hiresAttempt.rawResponse; escalated = true; }
        } catch (hErr) { console.warn(`hires retry failed: ${(hErr as Error).message}`); }
      }
    }
    const parsed = attempt.parsed;
    const rotationLog = attempt.rotationLog;
    const totalRotationDeg = attempt.totalRotationDeg;
    const directionCheck = deriveDirection(parsed, ctx);
    if (directionCheck.overridden) parsed.direction = directionCheck.direction;
    if (nameMatchesPlant(parsed.vendor_name, ctx) || gstinMatchesPlant(parsed.vendor_gstin, ctx)) {
      const sellerIsUs = nameMatchesPlant(parsed.seller_name, ctx) || gstinMatchesPlant(parsed.seller_gstin, ctx);
      const buyerIsUs  = nameMatchesPlant(parsed.buyer_name, ctx) || gstinMatchesPlant(parsed.buyer_gstin, ctx);
      if (sellerIsUs && !buyerIsUs && parsed.buyer_name) { parsed.vendor_name = parsed.buyer_name; parsed.vendor_gstin = parsed.buyer_gstin ?? null; }
      else if (buyerIsUs && !sellerIsUs && parsed.seller_name) { parsed.vendor_name = parsed.seller_name; parsed.vendor_gstin = parsed.seller_gstin ?? null; }
    }
    if (!parsed.is_document) {
      await supabase.from("mcp_logistics_extraction_queue").update({ status: "skipped", classification: "non_document", processed_at: new Date().toISOString(), extraction_ms: Date.now() - startedAt, error_message: null, raw_response: null, debug_payload: { worker_version: WORKER_VERSION, escalated_to_hires: escalated } }).eq("id", row.id);
      return { ok: true, queue_id: row.id, skipped: true };
    }
    const docType = resolveDocType(parsed);

    // Server-side arithmetic sanity check — catches Indian-comma misreads etc.
    const items = Array.isArray(parsed.items) ? parsed.items : [];
    const itemsSum = items.reduce((s: number, it: { amount?: number | null }) => s + (typeof it?.amount === "number" ? it.amount : 0), 0);
    const taxable = typeof parsed.taxable_value === "number" ? parsed.taxable_value : null;
    const tax = typeof parsed.tax_amount === "number" ? parsed.tax_amount : 0;
    const total = typeof parsed.total_value === "number" ? parsed.total_value : null;
    const issues: string[] = [];
    if (taxable && itemsSum > 0) {
      const gap = Math.abs(itemsSum - taxable);
      if (gap > Math.max(1, taxable * 0.02)) {
        const ratio = itemsSum > taxable ? itemsSum / taxable : taxable / itemsSum;
        issues.push(`items sum ${itemsSum.toFixed(2)} vs taxable ${taxable.toFixed(2)} (gap ₹${gap.toFixed(2)}, ratio ${ratio.toFixed(2)}×)${ratio > 8 && ratio < 12 ? " — likely Indian-comma misread (10×)" : ""}`);
      }
    }
    items.forEach((it: { qty?: number; rate?: number; amount?: number; name?: string }, idx: number) => {
      if (typeof it?.qty === "number" && typeof it?.rate === "number" && typeof it?.amount === "number") {
        const expected = it.qty * it.rate;
        if (Math.abs(expected - it.amount) > Math.max(1, it.amount * 0.02)) {
          issues.push(`line ${idx + 1} (${it.name ?? "?"}): qty×rate=${expected.toFixed(2)} but amount=${it.amount.toFixed(2)}`);
        }
      }
    });
    if (taxable && total) {
      const expected = taxable + tax;
      if (Math.abs(expected - total) > Math.max(1, total * 0.02)) {
        issues.push(`total ${total.toFixed(2)} != taxable+tax ${expected.toFixed(2)} (gap ₹${Math.abs(expected-total).toFixed(2)})`);
      }
    }
    const flagsList: string[] = Array.isArray(parsed.flags) ? [...parsed.flags] : [];
    let validationNote = parsed.validation_note ?? null;
    if (issues.length > 0) {
      if (!flagsList.includes("arithmetic_mismatch")) flagsList.push("arithmetic_mismatch");
      if (!flagsList.includes("needs_human_review")) flagsList.push("needs_human_review");
      const auditTrail = "⚠ SERVER ARITHMETIC CHECK FAILED:\n  • " + issues.join("\n  • ") + "\n→ Values held for human review. Verify each number before approving.";
      validationNote = validationNote ? auditTrail + "\n\nMODEL NOTE: " + validationNote : auditTrail;
      if (parsed.confidence === "high") parsed.confidence = "low";
    }
    let resolvedVendorId: string | null = null;
    if (parsed.vendor_match_id && /^[0-9a-f-]{36}$/i.test(parsed.vendor_match_id)) {
      const { data: v } = await supabase.from("mcp_logistics_vendors").select("id").eq("id", parsed.vendor_match_id).eq("plant_id", row.plant_id).maybeSingle();
      if (v) resolvedVendorId = v.id;
    }
    const rawExtraction = { ...parsed, flags: flagsList, validation_note: validationNote, _worker_version: WORKER_VERSION, _model: MODEL, _resolved_doc_type: docType, _resolved_vendor_id: resolvedVendorId, _server_arithmetic_issues: issues };
    stage = "persist";
    const { data: doc, error: docErr } = await supabase.from("mcp_logistics_documents").insert({
      plant_id: row.plant_id, doc_type: docType, doc_number: parsed.doc_number ?? null, doc_date: parsed.doc_date ?? null, due_date: parsed.due_date ?? null,
      vendor_id: resolvedVendorId, vendor_name_raw: parsed.vendor_name ?? null, vendor_gstin_raw: parsed.vendor_gstin ?? null,
      taxable_value: parsed.taxable_value ?? null, tax_amount: parsed.tax_amount ?? null, total_value: parsed.total_value ?? null,
      items: parsed.items ?? [], raw_extraction: rawExtraction, validation_note: validationNote,
      source_message_id: row.message_id, source_image_url: row.image_url,
      extracted_by_ai: true, extraction_status: "completed", status: "pending",
    }).select("id").single();
    if (docErr) throw docErr;
    const keepRawForDebug = parsed.confidence !== "high" || (parsed.flags && parsed.flags.length > 0);
    await supabase.from("mcp_logistics_extraction_queue").update({
      status: "completed", result_doc_id: doc.id, classification: "document", processed_at: new Date().toISOString(), extraction_ms: Date.now() - startedAt, error_message: null,
      raw_response: keepRawForDebug ? lastRawResponse?.slice(0, 8192) ?? null : null,
      debug_payload: { worker_version: WORKER_VERSION, model: MODEL, confidence: parsed.confidence ?? null, flags: flagsList, direction: parsed.direction ?? null, resolved_doc_type: docType, vendor_match_id: resolvedVendorId, auto_rotated_deg: totalRotationDeg, auto_rotated_iterations: rotationLog.length, auto_rotated_log: rotationLog, escalated_to_hires: escalated, image_source: escalated ? "hires" : "compressed", image_url_used: attempt.imageUrl, direction_override: directionCheck.overridden, direction_reason: directionCheck.reason, server_seller_is_us: directionCheck.computed_seller_is_us, server_buyer_is_us: directionCheck.computed_buyer_is_us, server_arithmetic_issues: issues },
    }).eq("id", row.id);
    return { ok: true, queue_id: row.id, doc_id: doc.id, doc_type: docType, direction: parsed.direction, confidence: parsed.confidence, flags: flagsList, auto_rotated_deg: totalRotationDeg, auto_rotated_log: rotationLog, escalated_to_hires: escalated };
  } catch (err) {
    const e = err as Error;
    await supabase.from("mcp_logistics_extraction_queue").update({
      status: "failed", raw_response: lastRawResponse?.slice(0, 8192) ?? null, error_message: `${stage}: ${e.message}`.slice(0, 500),
      debug_payload: { stage, exception_type: e.name, exception_message: e.message, stack: e.stack?.slice(0, 2000), model_used: MODEL, attempt_number: newAttempts, worker_version: WORKER_VERSION },
      processed_at: new Date().toISOString(), extraction_ms: Date.now() - startedAt,
    }).eq("id", row.id);
    return { ok: false, queue_id: row.id, error: `${stage}: ${e.message}` };
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" } });
  const supabase = createClient(SUPABASE_URL, SERVICE_KEY);
  try {
    let body: { queue_id?: string; batch_size?: number; reextract_doc_id?: string; force_hires?: boolean } = {};
    try { body = await req.json(); } catch {}
    const forceHires = body.force_hires === true;
    let rows: QueueRow[];
    if (body.reextract_doc_id) {
      const { data: srcDoc, error: srcErr } = await supabase.from("mcp_logistics_documents").select("id, plant_id, source_message_id, source_image_url").eq("id", body.reextract_doc_id).maybeSingle();
      if (srcErr) throw srcErr;
      if (!srcDoc) throw new Error("reextract_doc_id not found");
      if (!srcDoc.source_image_url) throw new Error("source doc has no source_image_url");
      const { data: q, error: qErr } = await supabase.from("mcp_logistics_extraction_queue").insert({ plant_id: srcDoc.plant_id, message_id: null, group_id: null, image_url: srcDoc.source_image_url, status: "pending" }).select("id, plant_id, message_id, group_id, image_url, attempts").single();
      if (qErr) throw qErr;
      rows = [q as QueueRow];
    } else if (body.queue_id) {
      const { data, error } = await supabase.from("mcp_logistics_extraction_queue").select("id, plant_id, message_id, group_id, image_url, attempts").eq("id", body.queue_id).limit(1);
      if (error) throw error;
      rows = (data ?? []) as QueueRow[];
    } else {
      const limit = Math.min(body.batch_size ?? 5, 10);
      const { data, error } = await supabase.from("mcp_logistics_extraction_queue").select("id, plant_id, message_id, group_id, image_url, attempts").eq("status", "pending").order("created_at", { ascending: true }).limit(limit);
      if (error) throw error;
      rows = (data ?? []) as QueueRow[];
    }
    const results = [];
    for (const row of rows) results.push(await processQueueRow(supabase, row, forceHires));
    const success = results.length > 0 && results.every(r => r.ok);
    return new Response(JSON.stringify({ success, processed: results.length, results, worker_version: WORKER_VERSION }, null, 2), { headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } });
  } catch (err) {
    const e = err as Error;
    return new Response(JSON.stringify({ success: false, error: e.message, stack: e.stack?.slice(0, 500) }), { status: 500, headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } });
  }
});
