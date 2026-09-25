// suggest-stock-hsn: AI suggests the Indian GST HSN code for stock items that
// don't have one. The item NAME (+ material/section) identifies the product;
// Claude maps it to the most appropriate HSN with a confidence. Suggestions are
// reviewed & applied by the user in the app (HSN affects GST — never blind-write).
// Deployed via Supabase MCP; this is the tracked mirror.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-4-6";
const MAX_OUT = 8192;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const PROMPT = `You assign the correct Indian GST HSN code to metal / fabrication stock items. Indian fabrication shop; assume iron / non-alloy steel unless the name clearly says otherwise (SS = stainless, AL = aluminium, brass, copper, CI = cast iron).

Give the most appropriate HSN. Prefer 8 digits; use 6 or 4 if genuinely unsure. Guidance (iron & non-alloy steel unless stated):
- Angles / channels / beams (sections) -> 7216: L-angle 72162100, U-channel 72163100, I/H beam 72163200 or 72163300.
- Flat-rolled >=600mm wide: hot-rolled 7208 (e.g. 72085290), cold-rolled 7209 (72092790), zinc/GI coated 7210 (72104900 / 72107000), colour-coated 7210.
- Flat-rolled <600mm wide: 7211 (72111390 / 72111990), coated 7212.
- Bars & rods: hot-rolled bars 7214 (round/square 72149910 / 72149990), other 7215; hot-rolled coil rod 7213.
- Wire -> 7217.
- Tubes / pipes: welded 7306 (square/rectangular hollow section 73066100 / 73066900, circular 73063090), seamless 7304.
- Stainless steel: flat 7219 / 7220, bars & angles 7222, tubes 7306 90.
- Aluminium: bars/profiles 7604, plates/sheets 7606, tubes 7608, foil 7607.
- Fasteners (bolt/nut/screw/washer) -> 7318. Welding electrodes/rods -> 8311.
- Paint -> 3208/3209/3210. Lubricating / turbine oil -> 2710 or 3403.
- If the line is a SERVICE (weighing, loading, transport, labour, machining charge) there is no goods HSN -> output hsn = NA.

For EACH input item output ONE pipe-delimited line, EXACTLY these 4 fields in order:
code|hsn|confidence|note
- hsn: digits only (e.g. 72163100), or NA if it is a service / not a good.
- confidence: high | med | low.
- note: short reason (e.g. "MS U-channel section"), or blank.
Output ONLY the pipe lines — no JSON, no header row, no commentary.`;

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
    const items = Array.isArray(body.items) ? body.items.slice(0, 120) : null;
    if (!items || !items.length) return json({ error: "items[] required" }, 400);

    const listText = items.map((it: Record<string, unknown>, i: number) =>
      `${i + 1}. code=${String(it.code || "").slice(0, 40)} | cat=${String(it.category || "")} | mat=${String(it.material || "")} | sec=${String(it.section || "")} | uom=${String(it.uom || "nos")} | name=${String(it.name || "").slice(0, 120)}`
    ).join("\n");

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: MAX_OUT,
        messages: [{ role: "user", content: [
          { type: "text", text: "ITEMS (one per line):\n" + listText },
          { type: "text", text: PROMPT },
        ] }],
      }),
    });
    if (!res.ok) { const t = await res.text(); return json({ error: "AI request failed (" + res.status + "): " + t.slice(0, 300) }, 502); }
    const msg = await res.json();
    if (msg.type === "error" || msg.error) return json({ error: msg.error?.message || "Claude API error" }, 502);
    const outText = (msg.content || []).filter((b: { type: string }) => b.type === "text").map((b: { text: string }) => b.text).join("\n");

    const byCode: Record<string, Record<string, unknown>> = {};
    for (const raw of outText.split(/\r?\n/)) {
      const line = raw.trim();
      if (!line || !line.includes("|") || line.startsWith("#")) continue;
      const p = line.split("|");
      if (p.length < 3) continue;
      const code = String(p[0]).trim();
      if (!code) continue;
      const hsnRaw = String(p[1] || "").trim();
      const isNa = /^na$/i.test(hsnRaw);
      const hsn = isNa ? null : hsnRaw.replace(/\D/g, "").slice(0, 8);
      const confidence = String(p[2] || "").trim().toLowerCase();
      const note = (p[3] || "").trim();
      byCode[code] = { code, hsn: hsn && hsn.length >= 4 ? hsn : null, confidence, note };
    }

    const lc: Record<string, Record<string, unknown>> = {};
    for (const k in byCode) lc[k.toLowerCase()] = byCode[k];
    const results = items.map((it: Record<string, unknown>) => {
      const code = String(it.code || "");
      const r = byCode[code] || lc[code.toLowerCase()] || null;
      return {
        id: it.id ?? null,
        code,
        hsn: r ? (r.hsn as string | null) : null,
        confidence: r ? r.confidence : null,
        note: r ? r.note : null,
      };
    });

    try {
      const svc = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
      const cost = (msg.usage?.input_tokens || 0) * 3 / 1e6 + (msg.usage?.output_tokens || 0) * 15 / 1e6;
      const { data: me } = await db.from("users").select("plant_id").eq("id", user.id).maybeSingle();
      if (me?.plant_id) await svc.from("ai_usage").insert({
        plant_id: me.plant_id, kind: "stock_hsn", model: MODEL,
        input_tokens: msg.usage?.input_tokens || 0, output_tokens: msg.usage?.output_tokens || 0,
        cost_usd: Number(cost.toFixed(6)),
      });
    } catch (_) { /* ignore */ }

    return json({ success: true, results });
  } catch (e) {
    return json({ error: (e as Error).message || "Internal error" }, 500);
  }
});
