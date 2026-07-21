// extract-ppap-characteristics: read an engineering drawing (PDF or image) and
// extract every inspectable characteristic — dimensions, tolerances and GD&T —
// as the single source of truth for a PPAP / FAI packet. Mirrors the other
// extract-* functions; PDF via the document block, image via the image block.
// Deployed via Supabase MCP; this file is the tracked mirror.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-4-6";
const MAX_OUT = 16000;

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

const PROMPT = `You are a quality engineer preparing a PPAP / First-Article inspection. Read this manufacturing drawing and extract EVERY inspectable characteristic — each dimension, tolerance and GD&T callout — as a clean list. This list is the single source of truth for the whole PPAP packet, so be thorough and accurate.

For EACH characteristic return:
- balloon_no: if the drawing already shows balloon/bubble numbers, use that number; otherwise number them sequentially starting at 1, roughly top-left to bottom-right.
- feature: a short label of what it is, e.g. "Ø88.0", "150.0", "R44", "Flatness", "Position Ø0.2", "Ra 1.6".
- char_type: one of dimension | gdt | note | material (gdt for geometric tolerances like flatness/position/runout; material for material/hardness/finish notes).
- classification: critical | major | minor | "" — infer from special-characteristic symbols or leave "" if none marked.
- nominal: the nominal value as a number (e.g. 88.0). null for GD&T/notes with no single nominal.
- tol_plus: upper tolerance as a number (e.g. 0.1 for ±0.1, 0.05 for +0.05/-0.02). null if none.
- tol_minus: lower tolerance as a POSITIVE number (e.g. 0.1 for ±0.1, 0.02 for +0.05/-0.02). For a ± tolerance both are the same. null if none.
- unit: mm | inch | deg | µm | HRC | "" (default mm for lengths).
- spec_text: the raw spec exactly as printed, e.g. "88.0 ±0.1", "Ø56 H7", "12.5 +0.1/-0", "// 0.05 A".
- method: a suggested measurement method/gauge for this feature — Vernier caliper, Micrometer, Bore gauge, Height gauge, CMM, Profilometer, Hardness tester, Plug gauge, etc.

Rules:
- Convert fits (H7, g6, js9) into the spec_text; leave tol_plus/tol_minus null unless the tolerance is numerically given.
- Skip title-block text, notes about revision/scale, and drawing-management info — only real inspectable characteristics.
- If a value is unclear, include it with your best read and note it in "notes".

Return ONLY valid JSON (no markdown):
{
  "characteristics": [
    {"balloon_no":1,"feature":"Ø88.0","char_type":"dimension","classification":"","nominal":88.0,"tol_plus":0.1,"tol_minus":0.1,"unit":"mm","spec_text":"Ø88.0 ±0.1","method":"Bore gauge"}
  ],
  "part_hint": {"part_number": null, "revision": null, "part_name": null},
  "confidence": "high|medium|low",
  "notes": "anything the engineer should double-check, or null"
}`;

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
    const imageB64: string = typeof body.image_base64 === "string" ? body.image_base64 : "";
    const pdfB64: string = typeof body.pdf_base64 === "string" ? body.pdf_base64 : "";
    const mime: string = typeof body.mime === "string" ? body.mime : "image/jpeg";
    if (!imageB64 && !pdfB64) return json({ error: "Provide a drawing (PDF or image)." }, 400);

    const content: unknown[] = [];
    if (pdfB64) content.push({ type: "document", source: { type: "base64", media_type: "application/pdf", data: pdfB64 } });
    if (imageB64) content.push({ type: "image", source: { type: "base64", media_type: mime, data: imageB64 } });
    content.push({ type: "text", text: PROMPT });

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({ model: MODEL, max_tokens: MAX_OUT, messages: [{ role: "user", content }] }),
    });
    const msg = await res.json();
    if (msg.type === "error" || msg.error) throw new Error(msg.error?.message || "Claude API error");
    const outText = (msg.content || []).filter((b: { type: string }) => b.type === "text").map((b: { text: string }) => b.text).join("\n");
    let data: { characteristics?: unknown[]; part_hint?: unknown; confidence?: string; notes?: string };
    try { data = JSON.parse(sliceJson(outText)); }
    catch { return json({ error: "Could not read the drawing", raw: outText.slice(0, 1500) }, 500); }

    const num = (v: unknown) => { const x = parseFloat(String(v ?? "").replace(/[^0-9.\-]/g, "")); return isFinite(x) ? x : null; };
    const CLASS = ["critical", "major", "minor", ""];
    const TYPE = ["dimension", "gdt", "note", "material"];
    const characteristics = (Array.isArray(data.characteristics) ? data.characteristics : []).map((raw, i) => {
      const c = raw as Record<string, unknown>;
      return {
        balloon_no: num(c.balloon_no) != null ? Math.round(num(c.balloon_no) as number) : (i + 1),
        feature: c.feature ? String(c.feature).trim().slice(0, 120) : "",
        char_type: TYPE.includes(String(c.char_type)) ? String(c.char_type) : "dimension",
        classification: CLASS.includes(String(c.classification)) ? String(c.classification) : "",
        nominal: num(c.nominal),
        tol_plus: num(c.tol_plus),
        tol_minus: num(c.tol_minus) != null ? Math.abs(num(c.tol_minus) as number) : null,
        unit: c.unit ? String(c.unit).trim().slice(0, 8) : "mm",
        spec_text: c.spec_text ? String(c.spec_text).trim().slice(0, 160) : "",
        method: c.method ? String(c.method).trim().slice(0, 60) : "",
      };
    }).filter((c) => c.feature);

    try {
      const svc = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
      const cost = (msg.usage?.input_tokens || 0) * 3 / 1e6 + (msg.usage?.output_tokens || 0) * 15 / 1e6;
      const { data: me } = await db.from("users").select("plant_id").eq("id", user.id).maybeSingle();
      if (me?.plant_id) await svc.from("ai_usage").insert({
        plant_id: me.plant_id, kind: "ppap_extract", model: MODEL,
        input_tokens: msg.usage?.input_tokens || 0, output_tokens: msg.usage?.output_tokens || 0,
        cost_usd: Number(cost.toFixed(6)),
      });
    } catch (_) { /* never fail on logging */ }

    return json({ success: true, characteristics, part_hint: data.part_hint || null, confidence: data.confidence || null, notes: data.notes || null });
  } catch (e) {
    return json({ error: (e as Error).message || "Internal error" }, 500);
  }
});
