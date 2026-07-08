// analyze-master-sheet: generic AI extraction of ANY master list (parts, tools,
// machines, customers, vendors, …) from a company's own Excel layout. The
// frontend parses the workbook (SheetJS) into { sheets:[{name,rows}] }, tells us
// which master it wants and the target fields, and Claude reads the whole thing
// and returns clean, deduped rows mapped to those fields. No fixed template.
// Sibling of analyze-stock-sheet. Deployed via Supabase MCP; tracked mirror.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-4-6";
const MAX_CHARS = 90000;
const MAX_OUT = 16000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

function sheetsToText(sheets: Array<{ name: string; rows: string[][] }>): string {
  let out = "";
  for (const s of sheets || []) {
    out += `\n===== SHEET: ${s.name} =====\n`;
    for (const r of s.rows || []) out += (r || []).join(" | ") + "\n";
    if (out.length > MAX_CHARS) { out = out.slice(0, MAX_CHARS) + "\n…(truncated)"; break; }
  }
  return out;
}
function sliceJson(text: string): string {
  const cleaned = text.replace(/^```json\s*/i, "").replace(/```\s*$/, "").trim();
  if (cleaned.startsWith("{")) return cleaned;
  const a = text.indexOf("{"), b = text.lastIndexOf("}");
  return a >= 0 && b > a ? text.slice(a, b + 1) : cleaned;
}

interface FieldSpec { key: string; desc: string }

function buildPrompt(label: string, singular: string, keyField: string, fields: FieldSpec[]): string {
  const fieldLines = fields.map((f) => `  - ${f.key}: ${f.desc}`).join("\n");
  const exampleObj = "{" + fields.map((f) => `"${f.key}": …`).join(", ") + "}";
  return `You are extracting a ${label.toUpperCase()} master list from a company's own spreadsheet. Every company lays out their sheet differently — title rows, sub-headings, merged/stacked cells, one logical record spanning several rows, section-per-sheet, extra/unrelated columns. Read it all and produce ONE clean, deduplicated list of ${label}.

GRANULARITY (critical): produce a concise master list — ONE row per distinct ${singular}. Merge rows that clearly describe the same ${singular} (matched by ${keyField}) and never output the same one twice. SKIP non-record rows: titles, sub-headings, column headers, blank rows, totals/subtotals, "prepared by", dates, signatures, page numbers.

For EACH ${singular}, produce an object with EXACTLY these fields:
${fieldLines}

Rules:
- Map the company's columns to these fields intelligently even when their header names differ. If a field is genuinely absent, use null (or the stated default).
- Do NOT invent data. Leave unknown optional fields null.
- Keep values concise and clean (trim stray spaces, drop units/currency symbols from numeric fields).

Return ONLY valid JSON (no markdown, no prose):
{
  "items": [ ${exampleObj} ],
  "summary": {"total_items": 0, "source": "which sheet(s) drove the list"},
  "confidence": "high|medium|low",
  "notes": "anything the user should double-check, or null"
}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const db = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: { user } } = await db.auth.getUser();
    if (!user) return json({ error: "Not signed in" }, 401);

    const body = await req.json().catch(() => ({}));
    const sheets = Array.isArray(body.sheets) ? body.sheets : null;
    const fields: FieldSpec[] = Array.isArray(body.fields) ? body.fields : [];
    const label = String(body.label || "records");
    const singular = String(body.singular || "record");
    const keyField = String(body.keyField || (fields[0]?.key ?? "code"));
    if (!sheets || !sheets.length) return json({ error: "sheets[] required" }, 400);
    if (!fields.length) return json({ error: "fields[] required" }, 400);

    const text = sheetsToText(sheets);
    if (!text.trim()) return json({ error: "No cell data found in the sheet." }, 400);
    const PROMPT = buildPrompt(label, singular, keyField, fields);

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: MAX_OUT,
        messages: [{ role: "user", content: [
          { type: "text", text: "FILE: " + (body.filename || "master.xlsx") + "\n\nSPREADSHEET CONTENT (pipe-separated cells, one row per line, one section per sheet):\n" + text },
          { type: "text", text: PROMPT },
        ] }],
      }),
    });
    const msg = await res.json();
    if (msg.type === "error" || msg.error) throw new Error(msg.error?.message || "Claude API error");
    const outText = (msg.content || []).filter((b: { type: string }) => b.type === "text").map((b: { text: string }) => b.text).join("\n");
    let data: { items?: unknown[] };
    try { data = JSON.parse(sliceJson(outText)); }
    catch { return json({ error: "Could not parse extraction", raw: outText.slice(0, 1500) }, 500); }

    // Keep only the declared fields; de-dup by keyField (defensive).
    const keys = fields.map((f) => f.key);
    const seen = new Set<string>();
    const items = (Array.isArray(data.items) ? data.items : []).map((raw) => {
      const it = raw as Record<string, unknown>;
      const row: Record<string, unknown> = {};
      for (const k of keys) row[k] = it[k] ?? null;
      return row;
    }).filter((row) => {
      const kv = String(row[keyField] ?? "").trim().toLowerCase();
      if (!kv) return true; // let the frontend generate/flag a missing key
      if (seen.has(kv)) return false;
      seen.add(kv);
      return true;
    });

    // Log usage (service role)
    try {
      const svc = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
      const cost = (msg.usage?.input_tokens || 0) * 3 / 1e6 + (msg.usage?.output_tokens || 0) * 15 / 1e6;
      const { data: me } = await db.from("users").select("plant_id").eq("id", user.id).maybeSingle();
      if (me?.plant_id) await svc.from("ai_usage").insert({
        plant_id: me.plant_id, kind: "master_extract:" + label, model: MODEL,
        input_tokens: msg.usage?.input_tokens || 0, output_tokens: msg.usage?.output_tokens || 0,
        cost_usd: Number(cost.toFixed(6)),
      });
    } catch (_) { /* never fail the extraction on logging */ }

    return json({ success: true, items, summary: data.summary || null, confidence: (data as { confidence?: string }).confidence || null, notes: (data as { notes?: string }).notes || null });
  } catch (e) {
    return json({ error: (e as Error).message || "Internal error" }, 500);
  }
});
