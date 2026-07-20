// suggest-pfmea — AI drafts a Process FMEA from a part's process flow +
// characteristics. Given the operations and the drawing characteristics (esp.
// CC/SC), Claude proposes, per step: failure modes, effects, causes, current
// controls, and S/O/D ratings (1-10). SUGGESTION ONLY — the client shows the
// draft for human review/edit before it's written to iatf_fmea / iatf_fmea_items.
// Synchronous: authenticates the caller (anon key + Authorization header) and
// returns the draft in the response. Mirrors analyze-stock-sheet's shape.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-4-6";
const MAX_OUT = 5000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

interface Step { seq?: number; operation?: string; machine?: string; control_method?: string }
interface Char { balloon_no?: string; description?: string; nominal?: number; tol_plus?: number; tol_minus?: number; uom?: string; classification?: string }

function buildPrompt(part: string, steps: Step[], chars: Char[]) {
  const stepLines = steps.map((s, i) => `  ${s.seq || i + 1}. ${s.operation || "(operation)"}${s.machine ? " on " + s.machine : ""}${s.control_method ? " — controls: " + s.control_method : ""}`).join("\n") || "  (no steps provided)";
  const keyChars = chars.filter(c => c.classification && c.classification !== "none");
  const charLines = (keyChars.length ? keyChars : chars).slice(0, 40).map(c => `  • ${c.balloon_no ? "[" + c.balloon_no + "] " : ""}${c.description || ""}${c.nominal != null ? " = " + c.nominal + (c.uom || "") : ""}${(c.tol_plus != null || c.tol_minus != null) ? " (tol +" + (c.tol_plus ?? 0) + "/-" + (c.tol_minus ?? 0) + ")" : ""}${c.classification && c.classification !== "none" ? " «" + String(c.classification).toUpperCase() + "»" : ""}`).join("\n") || "  (none)";
  return `You are a lead quality engineer facilitating a PROCESS FMEA (PFMEA) for an automotive component (AIAG-VDA / IATF 16949). Draft the PFMEA line items for the part below.

PART: ${part || "(unnamed)"}

PROCESS FLOW (operations, in sequence):
${stepLines}

KEY DRAWING CHARACTERISTICS (CC = critical/safety, SC = significant):
${charLines}

TASK: For EACH process operation, propose the most important 1-3 potential failure modes. For each, give a realistic effect, a likely cause, the typical current control, and severity/occurrence/detection ratings. Prioritise failure modes that jeopardise the CC/SC characteristics (higher severity). Be specific to the actual operations and characteristics — not generic.

RATING RULES (integers 1-10):
- severity: 10 = safety/regulatory; 7-8 = major function loss / customer line stop; 4-6 = degraded; 1-3 = minor/appearance. CC-linked failures are usually 8-10, SC usually 6-8.
- occurrence: 10 = very frequent; 1 = unlikely (robust/mistake-proofed).
- detection: 10 = cannot detect before customer; 1 = poka-yoke / automatic gauge catches it. Better controls = LOWER detection.

Return ONLY strict JSON, no prose, no markdown fences:
{"items":[{"step_no":1,"process_step":"CNC turning","function_text":"turn OD to spec","failure_mode":"OD oversize","failure_effect":"...","cause":"...","current_controls":"...","severity":8,"occurrence":3,"detection":4,"recommended_action":"..."}],"notes":"one short caveat or empty"}`;
}

function safeJson(text: string): { items?: unknown[]; notes?: string } {
  let s = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/i, "").trim();
  const a = s.indexOf("{"), b = s.lastIndexOf("}");
  if (a >= 0 && b > a) s = s.slice(a, b + 1);
  try { return JSON.parse(s); } catch { return {}; }
}
const clampR = (v: unknown) => { const n = Math.round(Number(v)); return isFinite(n) ? Math.min(10, Math.max(1, n)) : 5; };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const db = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false, autoRefreshToken: false } });
    const { data: { user } } = await db.auth.getUser();
    if (!user) return json({ error: "Not signed in" }, 401);

    const body = await req.json().catch(() => ({}));
    const steps: Step[] = Array.isArray(body.process_steps) ? body.process_steps : [];
    const chars: Char[] = Array.isArray(body.characteristics) ? body.characteristics : [];
    if (!steps.length && !chars.length) return json({ error: "Provide process_steps and/or characteristics." }, 400);

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({ model: MODEL, max_tokens: MAX_OUT, messages: [{ role: "user", content: buildPrompt(String(body.part_number || ""), steps, chars) }] }),
    });
    if (!res.ok) { const t = await res.text(); return json({ error: "AI request failed (" + res.status + "): " + t.slice(0, 300) }, 502); }
    const msg = await res.json();
    if (msg.type === "error" || msg.error) return json({ error: msg.error?.message || "Claude API error" }, 502);
    const outText = (msg.content || []).filter((b: { type: string }) => b.type === "text").map((b: { text: string }) => b.text).join("\n");
    const parsed = safeJson(outText);
    const raw = Array.isArray(parsed.items) ? parsed.items : [];
    if (!raw.length) return json({ error: "AI returned no PFMEA lines.", raw: outText.slice(0, 500) }, 200);

    const items = raw.map((r) => {
      const it = r as Record<string, unknown>;
      const sev = clampR(it.severity), occ = clampR(it.occurrence), det = clampR(it.detection);
      return {
        step_no: Number(it.step_no) || 1,
        process_step: String(it.process_step || "").slice(0, 200),
        function_text: String(it.function_text || "").slice(0, 300),
        failure_mode: String(it.failure_mode || "").slice(0, 300),
        failure_effect: String(it.failure_effect || "").slice(0, 400),
        cause: String(it.cause || "").slice(0, 400),
        current_controls: String(it.current_controls || "").slice(0, 400),
        severity: sev, occurrence: occ, detection: det, rpn: sev * occ * det,
        recommended_action: String(it.recommended_action || "").slice(0, 400),
      };
    }).sort((a, b) => b.rpn - a.rpn);

    try {
      const svc = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
      const cost = (msg.usage?.input_tokens || 0) * 3 / 1e6 + (msg.usage?.output_tokens || 0) * 15 / 1e6;
      const { data: me } = await db.from("users").select("plant_id").eq("id", user.id).maybeSingle();
      if (me?.plant_id) await svc.from("ai_usage").insert({ plant_id: me.plant_id, kind: "pfmea_draft", model: MODEL, input_tokens: msg.usage?.input_tokens || 0, output_tokens: msg.usage?.output_tokens || 0, cost_usd: Number(cost.toFixed(6)) });
    } catch (_) { /* metering never blocks */ }

    return json({ success: true, items, notes: (parsed.notes || "").toString().slice(0, 300) });
  } catch (e) {
    return json({ error: (e as Error).message || "Internal error" }, 500);
  }
});
