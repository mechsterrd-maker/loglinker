// extract-production-shots — batch voice → multiple PDC shot entries.
//
// Same dual-mode shape as extract-meeting-actions:
//   1. multipart/form-data with mode=transcribe → Whisper translates one mp3
//      chunk (Tamil / Hindi / mixed → English) and returns { transcript }.
//   2. application/json with { transcript, plant_id } → Claude Haiku extracts
//      a shots[] array from the joined transcript and returns { extraction }.
//
// Per-batch cost: Whisper ~₹0.50 for a 90-second dictation + Claude ~₹0.50
// for the extraction = ~₹1 total per shift's worth of shots — cheaper than
// the per-machine conversational flow once you're logging 2+ machines.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const OPENAI_KEY    = Deno.env.get("OPENAI_API_KEY")!;
const MODEL         = "claude-haiku-4-5";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

const STATIC_PROMPT = `You are an extraction engine for an Indian PDC (pressure die-casting) plant's production shot log.

INPUT: an English transcript translated from a shift-end voice dictation. The original audio was in Tamil, Hindi, Tanglish, Hinglish, English, or a mix. The operator lists production for one or more machines, often loosely (e.g. "Machine M1 die 654 shift A two-forty good eight reject flash, then M2 die 712 same shift one-eighty good zero reject…").

OUTPUT: strict JSON, NO markdown fences, NO commentary outside the braces:
{
  "shots": [
    {
      "machine_code":     "string — best match from PDC MACHINES list, or null",
      "die_code":         "string — best match from DIES list, or null",
      "shift_name":       "string — best match from SHIFTS list, or null",
      "shots_good":       <integer>,
      "shots_rejected":   <integer>,
      "reject_reason":    "short defect name (flash, porosity, short shot, cold shut, blister, ejector mark, dimensional, …) or null if zero rejects",
      "metal_consumed_kg": <number or null — only if operator stated it>,
      "raw_quote":         "the exact phrase from the transcript this row came from — used for human review"
    }
  ]
}

RULES:
- One element per (machine, die, shift) the operator mentioned. Same machine logged twice in one shift = two rows.
- machine_code MUST be picked from PDC MACHINES if any reasonable match exists. Operators speak codes loosely ("M1", "PDC one", "one twenty"). Fuzzy match.
- die_code: operators say "die six fifty four", "654 die", "D-654" — match flexibly against DIES.
- shift_name: prefer explicit mention. If not stated, infer from IST CURRENT TIME vs shifts' start/end. If genuinely ambiguous, null.
- If shots_good or shots_rejected can't be extracted for a row, SKIP that row — don't half-fill.
- "no rejects" / "zero reject" / "all good" / "vendraavadhu illa" → shots_rejected=0, reject_reason=null.
- Ignore greetings, chatter, non-production sentences.
- Number words: "two hundred forty" / "two forty" / "two-forty" all → 240.

If the transcript has no usable production data, return {"shots": []}.`;

async function transcribe(req: Request): Promise<Response> {
  const fd = await req.formData();
  const audio = fd.get("audio");
  if (!(audio instanceof File)) throw new Error("audio file is required");
  const hint = String(fd.get("hint_subject") || "").trim();

  const wForm = new FormData();
  wForm.set("file", audio);
  wForm.set("model", "whisper-1");
  // translations endpoint always returns English regardless of source language
  if (hint) wForm.set("prompt", hint);

  const wRes = await fetch("https://api.openai.com/v1/audio/translations", {
    method: "POST",
    headers: { Authorization: "Bearer " + OPENAI_KEY },
    body: wForm,
  });
  if (!wRes.ok) {
    const t = await wRes.text();
    throw new Error("whisper failed: " + t.slice(0, 400));
  }
  const w = await wRes.json();
  return json({ transcript: w.text || "" });
}

async function extract(req: Request): Promise<Response> {
  const supabase = createClient(SUPABASE_URL, SERVICE_KEY);
  const body = await req.json() as { transcript?: string; plant_id?: string };
  if (!body.plant_id) throw new Error("plant_id is required");
  if (!body.transcript || !body.transcript.trim()) throw new Error("transcript is required");

  const [m, d, sh] = await Promise.all([
    supabase.from("machines").select("code, make, status, units(name)").eq("plant_id", body.plant_id).eq("category", "pdc"),
    supabase.from("mcp_pdc_dies").select("code, part_number, customer_name").eq("plant_id", body.plant_id).neq("status", "retired"),
    supabase.from("shifts").select("name, start_time, end_time").eq("plant_id", body.plant_id).eq("is_active", true),
  ]);
  const machines = (m.data || []) as Array<{ code: string; make: string | null; status: string; units: { name: string } | null }>;
  const dies = (d.data || []) as Array<{ code: string; part_number: string; customer_name: string | null }>;
  const shifts = (sh.data || []) as Array<{ name: string; start_time: string; end_time: string }>;

  const now = new Date();
  const istHour = (now.getUTCHours() + 5) % 24;
  const istMin = (now.getUTCMinutes() + 30) % 60;

  const dynamic = `CURRENT IST TIME: ${istHour}:${String(istMin).padStart(2, "0")}

PDC MACHINES (${machines.length}):
${machines.map(x => `  • ${x.code} — ${x.make || "?"} (${x.units?.name || "?"}, ${x.status})`).join("\n") || "  (none)"}

DIES (${dies.length}):
${dies.map(x => `  • ${x.code} (part ${x.part_number}${x.customer_name ? ", " + x.customer_name : ""})`).join("\n") || "  (none)"}

SHIFTS (${shifts.length}):
${shifts.map(x => `  • "${x.name}" — ${x.start_time}–${x.end_time}`).join("\n") || "  (none)"}

TRANSCRIPT:
"""
${body.transcript.trim()}
"""`;

  const aRes = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 2000,
      system: [
        { type: "text", text: STATIC_PROMPT, cache_control: { type: "ephemeral" } },
        { type: "text", text: dynamic },
      ],
      messages: [{ role: "user", content: "Extract the shots." }],
    }),
  });
  if (!aRes.ok) {
    const t = await aRes.text();
    throw new Error("claude failed: " + t.slice(0, 400));
  }
  const a = await aRes.json();
  const raw = a.content?.[0]?.text || "{}";

  let cleaned = String(raw).trim();
  const fence = cleaned.match(/^```(?:json)?\s*\n?([\s\S]*?)\n?```$/);
  if (fence) cleaned = fence[1].trim();
  const start = cleaned.indexOf("{");
  const end = cleaned.lastIndexOf("}");
  if (start !== -1 && end !== -1) cleaned = cleaned.slice(start, end + 1);

  let parsed: { shots?: unknown };
  try { parsed = JSON.parse(cleaned); }
  catch { throw new Error("claude returned invalid JSON: " + String(raw).slice(0, 200)); }

  const shots = Array.isArray(parsed.shots) ? parsed.shots : [];
  return json({ extraction: { shots } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const ct = req.headers.get("content-type") || "";
    if (ct.includes("multipart/form-data")) return await transcribe(req);
    return await extract(req);
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
