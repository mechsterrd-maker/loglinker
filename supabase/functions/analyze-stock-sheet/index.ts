// analyze-stock-sheet: AI extraction of a stock/inventory list from ANY Excel
// layout. The frontend parses the workbook (SheetJS) into { sheets:[{name,rows}] }
// and posts it here; Claude reads the whole thing and returns a clean, deduped
// stock list regardless of how the company laid it out. No fixed template.
// Deployed via Supabase MCP; this file is the tracked mirror.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-4-6";
const MAX_CHARS = 90000; // cap the sheet text we send
const MAX_OUT = 16000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const PROMPT = `You are extracting a STOCK / INVENTORY master list from a company's own spreadsheet. Every company lays out their sheet differently — title rows, sub-headings, merged/stacked cells, one logical item spanning several rows, section-per-sheet, extra columns (invoice, warranty, serial no, location), embedded prices like "RATE - 3750 + TAX 675 = 4425". Read it all and produce ONE clean, deduplicated list of stock items.

GRANULARITY (critical): produce a concise STOCK list — ONE row per distinct item TYPE / model, with a QUANTITY. This is stock-on-hand, not an asset register. If a sheet lists the same model many times, once per physical unit (each with its own serial number, invoice, purchase date), COLLAPSE all of them into a SINGLE item whose opening_qty = the count of units. NEVER output one item per serial number or per physical machine. The result should be tens of items, not hundreds. When one sheet = one machine type with many unit-rows, that whole sheet is usually ONE stock item (qty = number of units).

RULES:
- If the workbook has a summary/overview sheet that already lists item types with quantities, THAT is your list — use its names and quantities as the master. Use the detailed per-machine sheets only to enrich (cost, spec, uom). Do NOT double-count (summary + details) and do NOT expand the summary back into per-unit rows.
- Merge the same item across rows/sheets and SUM quantities. Never output the same item twice.
- Multi-row entries: a single item's brand, serial no, specification, rate and invoice are often stacked in the rows just below its name — treat them as ONE item, not several.
- SKIP non-item rows: titles, sub-headings, column headers, blank rows, totals/subtotals, "prepared by", dates, signatures, invoice/warranty/serial-only lines.
- quantity = the on-hand / available quantity (columns named Qty, Qty avl, QTY, Stock, Balance, Nos, etc.). If truly absent, use 1.
- unit_cost = the per-unit price if present. From messy text like "RATE - 3750 + TAX 675 = 4425" take the final total (4425); if only a base rate is given, use that. Null if none.
- code = an existing item code / SKU / part no / internal number from the sheet if one clearly identifies the item; otherwise GENERATE a short uppercase code from the name (e.g. "AG4 Grinding machine" -> "AG4-GRINDER", max 24 chars, unique within your output).
- category = the TOP-LEVEL group, one of: raw_material, consumables, tools, packing, die_spares, bought_out, general. (Power tools / machines / drills / grinders / welders -> tools.)
- subcategory = the SPECIFIC type/group WITHIN the category, so items align neatly. Use the sheet name / section heading as a strong hint — companies group items by sheet or sub-heading and THAT grouping is usually the subcategory. Examples: a grinder under "tools" -> "Grinding Machines"; a welder -> "Welding Machines"; a drill -> "Drilling Machines"; a cut-off/plasma/bandsaw -> "Cutting Machines"; folding/shearing/rolling -> "Sheet Metal Machines"; an MS bar under "raw_material" -> "MS Steel". Title Case, concise (1-3 words). Group similar items under the SAME subcategory wording so they cluster. Null only if genuinely ungroupable.
- uom = the unit (nos, pcs, kg, ltr, set, etc.); default "nos" for countable tools/parts.
- name = a clean human item name (include key spec/model if it distinguishes the item, e.g. "AG5 Grinding Machine (DW831)").
- notes = optional short extra (location / spec) — keep brief or null.

Return ONLY valid JSON (no markdown, no prose):
{
  "items": [
    {"code":"AG4-GRINDER","name":"AG4 Grinding Machine","category":"tools","subcategory":"Grinding Machines","uom":"nos","opening_qty":2,"unit_cost":4425,"notes":null}
  ],
  "summary": {"total_items": 0, "total_qty": 0, "source": "which sheet(s) drove the list"},
  "confidence": "high|medium|low",
  "notes": "anything the user should double-check, or null"
}`;

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
    if (!sheets || !sheets.length) return json({ error: "sheets[] required" }, 400);

    const text = sheetsToText(sheets);
    if (!text.trim()) return json({ error: "No cell data found in the sheet." }, 400);

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: MAX_OUT,
        messages: [{ role: "user", content: [
          { type: "text", text: "FILE: " + (body.filename || "stock.xlsx") + "\n\nSPREADSHEET CONTENT (pipe-separated cells, one row per line, one section per sheet):\n" + text },
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

    // Normalize + de-dup by code (defensive)
    const seen = new Set<string>();
    const items = (Array.isArray(data.items) ? data.items : []).map((raw) => {
      const it = raw as Record<string, unknown>;
      let code = String(it.code || "").trim().toUpperCase().replace(/\s+/g, "-").slice(0, 24);
      if (!code) code = String(it.name || "ITEM").trim().toUpperCase().replace(/[^A-Z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 24) || "ITEM";
      let key = code, n = 1;
      while (seen.has(key)) key = code.slice(0, 20) + "-" + (++n);
      seen.add(key);
      const num = (v: unknown) => { const x = parseFloat(String(v ?? "").replace(/[^0-9.\-]/g, "")); return isFinite(x) ? x : null; };
      return {
        code: key,
        name: String(it.name || key).trim(),
        category: ["raw_material", "consumables", "tools", "packing", "die_spares", "bought_out", "general"].includes(String(it.category)) ? it.category : "general",
        subcategory: it.subcategory ? String(it.subcategory).trim().slice(0, 60) : null,
        uom: String(it.uom || "nos").trim() || "nos",
        opening_qty: num(it.opening_qty) ?? 1,
        unit_cost: num(it.unit_cost),
        notes: it.notes ? String(it.notes).slice(0, 200) : null,
      };
    });

    // Log usage (service role)
    try {
      const svc = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
      const cost = (msg.usage?.input_tokens || 0) * 3 / 1e6 + (msg.usage?.output_tokens || 0) * 15 / 1e6;
      const { data: me } = await db.from("users").select("plant_id").eq("id", user.id).maybeSingle();
      if (me?.plant_id) await svc.from("ai_usage").insert({
        plant_id: me.plant_id, kind: "stock_extract", model: MODEL,
        input_tokens: msg.usage?.input_tokens || 0, output_tokens: msg.usage?.output_tokens || 0,
        cost_usd: Number(cost.toFixed(6)),
      });
    } catch (_) { /* never fail the extraction on logging */ }

    return json({ success: true, items, summary: data.summary || null, confidence: (data as { confidence?: string }).confidence || null, notes: (data as { notes?: string }).notes || null });
  } catch (e) {
    return json({ error: (e as Error).message || "Internal error" }, 500);
  }
});
