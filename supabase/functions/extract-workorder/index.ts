// extract-workorder: read a work order / PO (PDF, photo, or Excel/CSV text,
// typically exported from Zoho) and pull the fields needed to auto-create a
// fabrication project in Loglinkr — so the user imports the WO instead of
// retyping it. Returns one project object the frontend reviews before creating.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-4-6";
const MAX_OUT = 4000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

function sliceJson(text: string): string {
  const cleaned = text.replace(/^```json\s*/i, "").replace(/```\s*$/, "").trim();
  if (cleaned.startsWith("{")) return cleaned;
  const a = text.indexOf("{"), b = text.lastIndexOf("}");
  return a >= 0 && b > a ? text.slice(a, b + 1) : cleaned;
}

function buildPrompt(customers: string[], today: string): string {
  return `You are reading a manufacturing WORK ORDER / purchase order (often exported from Zoho) to create a fabrication PROJECT. Extract the fields below from the document. It may be a PDF, a photo, or spreadsheet text, in any layout.

Today is ${today}. Convert any delivery / due / target date to YYYY-MM-DD.

Known customers in this plant (if the buyer matches one, use its EXACT name; otherwise use the name as written):
${customers.length ? customers.map((c) => "- " + c).join("\n") : "(none provided)"}

Return these fields:
- name: a clear, short project name. Prefer the product / item being fabricated, optionally with the customer, e.g. "Storage Tank 5KL for MRF" or "MS Structure Fabrication". Not the bare WO number.
- customer_name: the buyer / customer / bill-to party, matched to the list above when possible, else as written. null if none.
- po_number: the work order number / PO number / reference on the document. null if none.
- qty: the quantity as a number (total units / sets / nos). null if not clear.
- uom: the unit (nos, sets, kg, mtr, …). null if not clear.
- target_date: delivery / due / target date as YYYY-MM-DD, or null.
- notes: a short summary of key specs / line items / remarks (1-3 lines), or null.

Return ONLY valid JSON:
{
  "project": {"name": "...", "customer_name": null, "po_number": null, "qty": null, "uom": null, "target_date": null, "notes": null},
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
    const text: string = typeof body.text === "string" ? body.text.trim() : "";
    const imageB64: string = typeof body.image_base64 === "string" ? body.image_base64 : "";
    const pdfB64: string = typeof body.pdf_base64 === "string" ? body.pdf_base64 : "";
    const mime: string = typeof body.mime === "string" ? body.mime : "image/jpeg";
    const customers: string[] = Array.isArray(body.customers) ? body.customers.filter(Boolean).map(String) : [];
    const today: string = typeof body.today === "string" && /^\d{4}-\d{2}-\d{2}$/.test(body.today) ? body.today : new Date().toISOString().slice(0, 10);

    if (!text && !imageB64 && !pdfB64) return json({ error: "Provide a work order (PDF, image, or text)." }, 400);

    const content: unknown[] = [];
    if (pdfB64) content.push({ type: "document", source: { type: "base64", media_type: "application/pdf", data: pdfB64 } });
    if (imageB64) content.push({ type: "image", source: { type: "base64", media_type: mime, data: imageB64 } });
    if (text) content.push({ type: "text", text: "WORK ORDER CONTENT:\n" + text });
    else content.push({ type: "text", text: "The work order is in the attached file above." });
    content.push({ type: "text", text: buildPrompt(customers, today) });

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({ model: MODEL, max_tokens: MAX_OUT, messages: [{ role: "user", content }] }),
    });
    const msg = await res.json();
    if (msg.type === "error" || msg.error) throw new Error(msg.error?.message || "Claude API error");
    const outText = (msg.content || []).filter((b: { type: string }) => b.type === "text").map((b: { text: string }) => b.text).join("\n");
    let data: { project?: Record<string, unknown>; confidence?: string; notes?: string };
    try { data = JSON.parse(sliceJson(outText)); }
    catch { return json({ error: "Could not read the work order", raw: outText.slice(0, 1500) }, 500); }

    const p = (data.project || {}) as Record<string, unknown>;
    const num = (v: unknown) => { const x = parseFloat(String(v ?? "").replace(/[^0-9.\-]/g, "")); return isFinite(x) ? x : null; };
    const project = {
      name: p.name ? String(p.name).trim().slice(0, 160) : "",
      customer_name: p.customer_name ? String(p.customer_name).trim() : "",
      po_number: p.po_number ? String(p.po_number).trim().slice(0, 60) : "",
      qty: num(p.qty),
      uom: p.uom ? String(p.uom).trim().slice(0, 12) : "",
      target_date: p.target_date && /^\d{4}-\d{2}-\d{2}$/.test(String(p.target_date)) ? String(p.target_date) : "",
      notes: p.notes ? String(p.notes).slice(0, 500) : "",
    };

    try {
      const svc = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
      const cost = (msg.usage?.input_tokens || 0) * 3 / 1e6 + (msg.usage?.output_tokens || 0) * 15 / 1e6;
      const { data: me } = await db.from("users").select("plant_id").eq("id", user.id).maybeSingle();
      if (me?.plant_id) await svc.from("ai_usage").insert({
        plant_id: me.plant_id, kind: "workorder_extract", model: MODEL,
        input_tokens: msg.usage?.input_tokens || 0, output_tokens: msg.usage?.output_tokens || 0,
        cost_usd: Number(cost.toFixed(6)),
      });
    } catch (_) { /* never fail on logging */ }

    return json({ success: true, project, confidence: data.confidence || null, notes: data.notes || null });
  } catch (e) {
    return json({ error: (e as Error).message || "Internal error" }, 500);
  }
});
