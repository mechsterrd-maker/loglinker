// ocr-model-trial/index.ts — READ-ONLY A/B harness: Sonnet (cached) vs Haiku.
//
// Runs a plant's already-uploaded bill images through BOTH models with the exact
// same system prompt + plant context that production (extract-document v25) uses,
// and returns a side-by-side comparison of extracted fields, tokens and INR cost.
//
// Safety: this NEVER writes to mcp_logistics_documents, ai_usage, or the OCR cap.
// It is a pure measurement tool. Default target is the "wew" plant; override with
// {plant_id} or {doc_ids:[...]} in the POST body.
//
// Why it exists: as of this trial NO bill has run through v24/v25, so the projected
// "Haiku is cheaper but maybe less accurate" tradeoff is untested on real Indian
// invoices. This measures it before any production model switch.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SYSTEM_PROMPT, buildContext, PromptContext } from "./prompt.ts";

const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;

const SONNET = "claude-sonnet-4-20250514";
const HAIKU  = "claude-haiku-4-5-20251001";
const WEW_PLANT_ID = "e28989f4-4174-4bcd-9382-19a36af77092";
const USD_TO_INR = 86;

// USD per token. Sonnet 4: 3/15. Haiku 4.5: 1/5. Cache: write 1.25×in, read 0.1×in.
const PRICING: Record<string, { in: number; out: number }> = {
  [SONNET]: { in: 3 / 1e6, out: 15 / 1e6 },
  [HAIKU]:  { in: 1 / 1e6, out: 5 / 1e6 },
};

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 32768;
  for (let i = 0; i < bytes.length; i += chunk) binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  return btoa(binary);
}

function safeJsonParse(raw: string): unknown {
  let s = raw.trim();
  const fence = s.match(/^```(?:json)?\s*\n?([\s\S]*?)\n?```$/);
  if (fence) s = fence[1].trim();
  const a = s.indexOf("{"), b = s.indexOf("[");
  const start = a === -1 ? b : b === -1 ? a : Math.min(a, b);
  if (start > 0) s = s.slice(start);
  const c = s.lastIndexOf("}"), d = s.lastIndexOf("]");
  const end = Math.max(c, d);
  if (end > 0 && end < s.length - 1) s = s.slice(0, end + 1);
  try { return JSON.parse(s); } catch { return { _parse_error: true, _raw: raw.slice(0, 400) }; }
}

function costInr(model: string, u: Record<string, number>): number {
  const p = PRICING[model];
  const freshIn = u.input_tokens ?? 0;
  const cWrite  = u.cache_creation_input_tokens ?? 0;
  const cRead   = u.cache_read_input_tokens ?? 0;
  const out     = u.output_tokens ?? 0;
  const usd = freshIn * p.in + cWrite * p.in * 1.25 + cRead * p.in * 0.1 + out * p.out;
  return Math.round(usd * USD_TO_INR * 1e4) / 1e4;
}

async function callModel(model: string, imgB64: string, mediaType: string, contextText: string) {
  const t0 = Date.now();
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({
      model, max_tokens: 3072,
      system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: [
        { type: "image", source: { type: "base64", media_type: mediaType, data: imgB64 } },
        { type: "text", text: contextText },
      ] }],
    }),
  });
  const ms = Date.now() - t0;
  if (!res.ok) return { model, ok: false, error: `${res.status}: ${(await res.text()).slice(0, 300)}`, ms };
  const data = await res.json();
  const text = data.content?.filter((b: { type: string }) => b.type === "text")?.map((b: { text: string }) => b.text)?.join("\n") ?? "";
  const parsed = safeJsonParse(text) as Record<string, unknown>;
  const u = data.usage ?? {};
  // Slim view of the fields that matter for an accuracy eyeball.
  const fields = {
    doc_type: parsed.doc_type, direction: parsed.direction, doc_number: parsed.doc_number,
    doc_date: parsed.doc_date, vendor_name: parsed.vendor_name, vendor_gstin: parsed.vendor_gstin,
    taxable_value: parsed.taxable_value, tax_amount: parsed.tax_amount, total_value: parsed.total_value,
    n_items: Array.isArray(parsed.items) ? parsed.items.length : 0,
    confidence: parsed.confidence, flags: parsed.flags, validation_note: parsed.validation_note,
  };
  return {
    model, ok: true, ms, fields, items: parsed.items ?? [],
    usage: { input: u.input_tokens ?? 0, output: u.output_tokens ?? 0, cache_write: u.cache_creation_input_tokens ?? 0, cache_read: u.cache_read_input_tokens ?? 0 },
    inr: costInr(model, u),
  };
}

async function fetchContext(supabase: ReturnType<typeof createClient>, plantId: string): Promise<PromptContext> {
  const { data: plant } = await supabase.from("plants").select("name, legal_name, gstin").eq("id", plantId).maybeSingle();
  const { data: units } = await supabase.from("units").select("id, name, address").eq("plant_id", plantId).order("name");
  const { data: vendors } = await supabase.from("mcp_logistics_vendors").select("id, name, legal_name, gstin, is_jobwork_vendor").eq("plant_id", plantId).order("updated_at", { ascending: false }).limit(60);
  const { data: items } = await supabase.from("mcp_stocks_items").select("id, code, name").eq("plant_id", plantId).order("updated_at", { ascending: false }).limit(80);
  return {
    plantName: (plant as { name?: string })?.name ?? "(unknown)",
    plantLegalName: (plant as { legal_name?: string })?.legal_name ?? null,
    plantGstin: (plant as { gstin?: string })?.gstin ?? null,
    units: (units ?? []) as PromptContext["units"],
    vendors: (vendors ?? []) as PromptContext["vendors"],
    stockItems: (items ?? []) as PromptContext["stockItems"],
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" } });
  const supabase = createClient(SUPABASE_URL, SERVICE_KEY);
  try {
    let body: { plant_id?: string; doc_ids?: string[]; limit?: number } = {};
    try { body = await req.json(); } catch {}
    const plantId = body.plant_id ?? WEW_PLANT_ID;
    const limit = Math.min(body.limit ?? 5, 10);

    let q = supabase.from("mcp_logistics_documents")
      .select("id, doc_number, source_image_url, taxable_value, tax_amount, total_value, raw_extraction")
      .eq("plant_id", plantId).not("source_image_url", "is", null)
      .order("created_at", { ascending: true }).limit(limit);
    if (body.doc_ids?.length) q = supabase.from("mcp_logistics_documents")
      .select("id, doc_number, source_image_url, taxable_value, tax_amount, total_value, raw_extraction")
      .in("id", body.doc_ids);
    const { data: docs, error } = await q;
    if (error) throw error;
    if (!docs?.length) return new Response(JSON.stringify({ error: "no docs with images for this plant", plant_id: plantId }), { status: 404, headers: { "Content-Type": "application/json" } });

    const ctx = await fetchContext(supabase, plantId);
    const contextText = buildContext(ctx);

    const comparisons = [];
    let sonnetInr = 0, haikuInr = 0;
    for (const doc of docs) {
      const imgRes = await fetch(doc.source_image_url as string);
      if (!imgRes.ok) { comparisons.push({ doc_id: doc.id, error: `image fetch ${imgRes.status}` }); continue; }
      let mt = (imgRes.headers.get("content-type") || "image/jpeg").split(";")[0].trim();
      if (!["image/jpeg","image/png","image/webp","image/gif"].includes(mt)) mt = "image/jpeg";
      const b64 = bytesToBase64(new Uint8Array(await imgRes.arrayBuffer()));
      // Run sequentially: Sonnet first writes the cache, Haiku reuses neither (different
      // model = separate cache), so each model's reported cost is standalone-realistic.
      const sonnet = await callModel(SONNET, b64, mt, contextText);
      const haiku  = await callModel(HAIKU,  b64, mt, contextText);
      if (sonnet.ok) sonnetInr += sonnet.inr ?? 0;
      if (haiku.ok)  haikuInr  += haiku.inr ?? 0;
      comparisons.push({
        doc_id: doc.id, doc_number: doc.doc_number,
        stored: { taxable: doc.taxable_value, tax: doc.tax_amount, total: doc.total_value, prev_ver: (doc.raw_extraction as Record<string, unknown>)?._worker_version },
        sonnet, haiku,
      });
    }

    return new Response(JSON.stringify({
      trial: "sonnet_cached_vs_haiku", plant: ctx.plantName, plant_id: plantId, docs_tested: docs.length,
      totals_inr: { sonnet: Math.round(sonnetInr * 100) / 100, haiku: Math.round(haikuInr * 100) / 100,
                    haiku_saving_pct: sonnetInr > 0 ? Math.round((1 - haikuInr / sonnetInr) * 100) : null },
      note: "READ-ONLY trial — wrote nothing to documents/ai_usage/OCR cap. Compare fields per doc for accuracy.",
      comparisons,
    }, null, 2), { headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } });
  } catch (err) {
    const e = err as Error;
    return new Response(JSON.stringify({ error: e.message, stack: e.stack?.slice(0, 400) }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
