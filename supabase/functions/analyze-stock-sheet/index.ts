// analyze-stock-sheet: AI extraction of a stock/inventory list from ANY Excel
// layout. The frontend parses the workbook (SheetJS) into { sheets:[{name,rows}] }
// and posts it here; Claude reads the whole thing and returns a clean, deduped
// stock list regardless of how the company laid it out. No fixed template.
//
// Speed/robustness: Claude replies in COMPACT pipe-delimited rows (not verbose
// per-item JSON) — ~3× fewer output tokens, so even a several-hundred-SKU sheet
// finishes well inside the platform's wall-clock limit. Wide day-by-day movement
// ledgers are trimmed (column cap) so they don't dominate the prompt. Plain
// (non-streamed) JSON response so real errors surface with a proper status code.
// Deployed via Supabase MCP; this file is the tracked mirror.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-4-6";
const MAX_CHARS = 90000;  // cap the sheet text we send
const MAX_COLS = 40;      // cap columns per row (day-by-day ledgers can be 100+ wide)
const MAX_OUT = 8192;     // compact rows ~12-18 tok/item → ~450-650 items; model-safe cap

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const PROMPT = `You are extracting a STOCK / INVENTORY master list from a company's own spreadsheet. Every company lays out their sheet differently — title rows, sub-headings, merged/stacked cells, one logical item spanning several rows, section-per-sheet, extra columns (invoice, warranty, serial no, location), embedded prices like "RATE - 3750 + TAX 675 = 4425". Read it all and produce ONE clean, deduplicated list of stock items.

WHICH SHEET IS THE LIST:
- If a sheet is clearly a STOCK MASTER (columns like Item Code, Description, UOM, Qty/Balance/Closing, Rate) use THAT as your list — one output row per data row.
- IGNORE day-by-day movement ledgers (sheets that are mostly a wide grid of dates / daily in-out numbers) — they are transactions, not stock. Never emit an item per ledger column or per day.
- If a summary/overview sheet already lists item types with quantities, use its names+quantities as the master; use detail sheets only to enrich (cost, spec, uom). Never double-count summary + details.

GRANULARITY:
- A distinct SIZE / THICKNESS / MODEL / grade with its own item code or spec IS a distinct stock item — keep them separate (e.g. "MS FLAT 40*5" and "MS FLAT 40*10" are two items).
- But if the SAME model is listed once per physical unit (each with its own serial no / invoice / purchase date), COLLAPSE those into ONE item whose quantity = the number of units. Never output one row per serial number.
- Merge a truly identical item appearing twice and SUM quantities. Multi-row entries (brand / serial / spec / rate stacked below a name) are ONE item.
- SKIP non-item rows: titles, sub-headings, column headers, blank rows, totals/subtotals, "prepared by", dates, signatures, invoice/warranty-only lines.

PER-FIELD RULES:
- code = existing item code / SKU / part no from the sheet if present; else GENERATE a short uppercase code from the name (max 24 chars).
- name = clean human item name incl. key spec/size if it distinguishes the item.
- category = one of: raw_material, consumables, tools, packing, die_spares, bought_out, general. (Power tools/machines → tools; steel/bar/flat/sheet → raw_material.)
- subcategory = specific group WITHIN the category (Title Case, 1-3 words). Use the sheet name / section heading as a strong hint. Empty if genuinely ungroupable.
- uom = unit (nos, pcs, kg, mtr, ltr, set…); default nos for countable items.
- opening_qty = the on-hand / closing / balance quantity (Qty, Balance, Closing, Stock, Nos…). If truly absent use 1.
- unit_cost = per-unit price if present. From "RATE - 3750 + TAX 675 = 4425" take the final total (4425). Empty if none.
- notes = optional short spec/location, or empty.

OUTPUT FORMAT — return ONLY plain text, NOTHING ELSE (no JSON, no markdown, no prose, no header row).
Optionally a FIRST line: #META confidence=high|medium|low; note=<one short caveat or blank>
Then ONE stock item PER LINE, pipe-delimited, EXACTLY these 8 fields in this order:
code|name|category|subcategory|uom|opening_qty|unit_cost|notes
Leave a field empty (nothing between the pipes) when it does not apply. Example:
#META confidence=high; note=
MSFL40-10|MS Flat 40*10|raw_material|MS Steel|mtr|15|48|
AG4-GRINDER|AG4 Grinding Machine|tools|Grinding Machines|nos|2|4425|shop floor`;

function sheetsToText(sheets: Array<{ name: string; rows: string[][] }>): string {
  let out = "";
  for (const s of sheets || []) {
    out += `\n===== SHEET: ${s.name} =====\n`;
    for (const r of s.rows || []) {
      out += (r || []).slice(0, MAX_COLS).join(" | ") + "\n";
      if (out.length > MAX_CHARS) return out.slice(0, MAX_CHARS) + "\n…(truncated)";
    }
  }
  return out;
}

const CATS = ["raw_material", "consumables", "tools", "packing", "die_spares", "bought_out", "general"];

function parseRows(text: string): { items: Record<string, unknown>[]; confidence: string | null; notes: string | null } {
  const lines = text.replace(/```[a-z]*/gi, "").split(/\r?\n/);
  let confidence: string | null = null, notes: string | null = null;
  const items: Record<string, unknown>[] = [];
  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith("#META")) {
      const cm = line.match(/confidence\s*=\s*(high|medium|low)/i);
      if (cm) confidence = cm[1].toLowerCase();
      const nm = line.match(/note\s*=\s*(.+)$/i);
      if (nm && nm[1].trim()) notes = nm[1].trim();
      continue;
    }
    if (line.startsWith("#") || line.startsWith("=====")) continue;
    if (!line.includes("|")) continue;
    const p = line.split("|");
    if (p.length < 6) continue;               // needs at least the core fields
    items.push({ code: p[0], name: p[1], category: p[2], subcategory: p[3], uom: p[4], opening_qty: p[5], unit_cost: p[6], notes: p[7] });
  }
  return { items, confidence, notes };
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
    if (!res.ok) {
      const t = await res.text();
      return json({ error: "AI request failed (" + res.status + "): " + t.slice(0, 300) }, 502);
    }
    const msg = await res.json();
    if (msg.type === "error" || msg.error) return json({ error: msg.error?.message || "Claude API error" }, 502);
    const outText = (msg.content || []).filter((b: { type: string }) => b.type === "text").map((b: { text: string }) => b.text).join("\n");

    const { items: raw, confidence, notes } = parseRows(outText);
    if (!raw.length) return json({ error: "No stock items were found in the file.", raw: outText.slice(0, 800) }, 200);

    // Normalize + de-dup by code (defensive)
    const seen = new Set<string>();
    const num = (v: unknown) => { const x = parseFloat(String(v ?? "").replace(/[^0-9.\-]/g, "")); return isFinite(x) ? x : null; };
    const items = raw.map((it) => {
      let code = String(it.code || "").trim().toUpperCase().replace(/\s+/g, "-").slice(0, 24);
      if (!code) code = String(it.name || "ITEM").trim().toUpperCase().replace(/[^A-Z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 24) || "ITEM";
      let key = code, n = 1;
      while (seen.has(key)) key = code.slice(0, 20) + "-" + (++n);
      seen.add(key);
      return {
        code: key,
        name: String(it.name || key).trim(),
        category: CATS.includes(String(it.category)) ? it.category : "general",
        subcategory: it.subcategory ? String(it.subcategory).trim().slice(0, 60) : null,
        uom: String(it.uom || "nos").trim() || "nos",
        opening_qty: num(it.opening_qty) ?? 1,
        unit_cost: num(it.unit_cost),
        notes: it.notes ? String(it.notes).slice(0, 200) : null,
      };
    });

    // Log usage (service role) — never fails the extract
    try {
      const svc = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
      const cost = (msg.usage?.input_tokens || 0) * 3 / 1e6 + (msg.usage?.output_tokens || 0) * 15 / 1e6;
      const { data: me } = await db.from("users").select("plant_id").eq("id", user.id).maybeSingle();
      if (me?.plant_id) await svc.from("ai_usage").insert({
        plant_id: me.plant_id, kind: "stock_extract", model: MODEL,
        input_tokens: msg.usage?.input_tokens || 0, output_tokens: msg.usage?.output_tokens || 0,
        cost_usd: Number(cost.toFixed(6)),
      });
    } catch (_) { /* ignore */ }

    return json({
      success: true, items,
      summary: { total_items: items.length, total_qty: items.reduce((s, i) => s + (Number(i.opening_qty) || 0), 0), source: null },
      confidence, notes,
    });
  } catch (e) {
    return json({ error: (e as Error).message || "Internal error" }, 500);
  }
});
