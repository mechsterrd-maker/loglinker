// extract-production-shots — batch voice → multiple production entries.
//
// Two output shapes share one Whisper-then-Claude pipeline:
//   • category="pdc"  → returns { shots: [...] }     for direct mcp_pdc_shots insert
//   • category=other  → returns { segments: [...] }  for submit_shift_segments RPC
//
// Modes:
//   1. multipart/form-data with mode=transcribe → Whisper translates one mp3
//      chunk (Tamil / Hindi / mixed → English) and returns { transcript }.
//   2. application/json with { transcript, plant_id, category } → Claude Haiku
//      extracts the structured array.
//
// Cost: Whisper ~₹0.50 for a 90-sec dictation + Claude ~₹0.50 = ~₹1 per
// shift's worth of entries.

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

// =============================================================================
// PROMPTS
// =============================================================================

const PDC_PROMPT = `You are an extraction engine for an Indian PDC (pressure die-casting) plant's production shot log.

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

const STAGE_PROMPT = `You are an extraction engine for an Indian SME manufacturing plant's daily stage log (machining operations — CNC, VMC, lathe, press, etc.).

INPUT: an English transcript translated from a shift-end voice dictation. The original audio was in Tamil / Hindi / Tanglish / Hinglish / English / mixed. The supervisor lists production for one or more machines.

CRUCIAL: operators are NOT precise. They use general terms. You MUST match loosely:
- Part may be said by part_number ("XYZ-123"), by name ("the big bracket", "support arm"), by customer alias ("Bosch part", "the Marvel one"), or by description. Try ALL of these.
- Operation may be said as op number ("op 10", "first operation"), op name ("facing op", "drilling"), or generic ("first stage", "next op"). Match against the part's route steps.
- Machine code is often loose: "CNC one", "CNC zero one", "machine number 3".
- When you're uncertain between two candidates, set the field to null AND add a note in raw_quote — a human will pick from a dropdown.

OUTPUT: strict JSON, NO markdown fences, NO commentary:
{
  "segments": [
    {
      "machine_code":  "exact code from MACHINES list, or null if unmatchable",
      "part_number":   "exact part_number from PARTS list, or null",
      "op_seq":        <integer — route step op_seq, or null if no clear match>,
      "op_name":       "exact op_name from the part's ROUTE STEPS, or null",
      "qty_good":      <integer>,
      "qty_rejected":  <integer>,
      "reject_reason": "short defect name, or null if zero rejects",
      "setup_change":  <boolean — true only if operator explicitly mentioned setup change / part changeover>,
      "raw_quote":     "the phrase from the transcript this row came from — for human review"
    }
  ]
}

MATCHING RULES:
- Try part_number → name → aliases (in that order). Pick the part that best fits the operator's words.
- If two parts are plausibly the same description, choose the one whose route includes the operation the operator mentioned.
- op_seq + op_name must both come from the SAME route step of the resolved part. If you set part_number, set BOTH op_seq and op_name (or both null).
- If operator says only "made 200 good on CNC-1" without naming a part, return part_number=null, op_seq=null, op_name=null — human will fill in.
- If qty_good and qty_rejected can't both be extracted (or inferred zero), SKIP that segment — don't half-fill.
- "no rejects" / "zero" / "all good" / "vendraavadhu illa" → qty_rejected=0, reject_reason=null.
- "setup change" / "part change" / "changeover" / "new part started" → setup_change=true.
- Ignore greetings, chatter, non-production sentences.
- Number words → integers ("two hundred forty" → 240).

If the transcript has no usable production data, return {"segments": []}.`;

// =============================================================================
// MODES
// =============================================================================

async function transcribe(req: Request): Promise<Response> {
  const fd = await req.formData();
  const audio = fd.get("audio");
  if (!(audio instanceof File)) throw new Error("audio file is required");
  const hint = String(fd.get("hint_subject") || "").trim();

  const wForm = new FormData();
  wForm.set("file", audio);
  wForm.set("model", "whisper-1");
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

async function extractPdc(
  supabase: ReturnType<typeof createClient>,
  plantId: string,
  transcript: string,
): Promise<Response> {
  const [m, d, sh] = await Promise.all([
    supabase.from("machines").select("code, make, status, units(name)").eq("plant_id", plantId).eq("category", "pdc"),
    supabase.from("mcp_pdc_dies").select("code, part_number, customer_name").eq("plant_id", plantId).neq("status", "retired"),
    supabase.from("shifts").select("name, start_time, end_time").eq("plant_id", plantId).eq("is_active", true),
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
${transcript.trim()}
"""`;

  const a = await callClaude(PDC_PROMPT, dynamic);
  const shots = Array.isArray((a as any)?.shots) ? (a as any).shots : [];
  return json({ extraction: { shots } });
}

async function extractStage(
  supabase: ReturnType<typeof createClient>,
  plantId: string,
  category: string,
  transcript: string,
): Promise<Response> {
  const [machinesRes, partsRes, routeStepsRes, aliasesRes] = await Promise.all([
    supabase.from("machines").select("code, make, display_name, status, units(name)").eq("plant_id", plantId).eq("category", category),
    supabase.from("mcp_pdc_parts").select("part_number, name, customer_id").eq("plant_id", plantId).eq("is_active", true),
    supabase.from("v_part_route_steps").select("part_id, part_number, op_seq, op_name, op_number, op_type").order("part_id").order("op_seq"),
    supabase.from("customer_part_aliases").select("internal_part_id, customer_alias, mcp_sched_customers(name)"),
  ]);

  const machines = (machinesRes.data || []) as Array<{ code: string; make: string | null; display_name: string | null; status: string; units: { name: string } | null }>;
  const parts = (partsRes.data || []) as Array<{ part_number: string; name: string; customer_id: string | null }>;
  const routeSteps = (routeStepsRes.data || []) as Array<{ part_id: string; part_number: string; op_seq: number; op_name: string | null; op_number: string | null; op_type: string | null }>;
  const aliases = (aliasesRes.data || []) as Array<{ internal_part_id: string; customer_alias: string; mcp_sched_customers: { name: string } | null }>;

  // Group route steps by part_number for the prompt
  const stepsByPart: Record<string, Array<{ op_seq: number; op_name: string | null; op_number: string | null; op_type: string | null }>> = {};
  for (const s of routeSteps) {
    if (!stepsByPart[s.part_number]) stepsByPart[s.part_number] = [];
    stepsByPart[s.part_number].push({ op_seq: s.op_seq, op_name: s.op_name, op_number: s.op_number, op_type: s.op_type });
  }

  // Group aliases by part_number (we need to join via internal_part_id → parts.id which we don't have here;
  // re-fetch the parts with id to map). Quick correction: fetch ids alongside.
  const { data: partIdMap } = await supabase
    .from("mcp_pdc_parts").select("id, part_number").eq("plant_id", plantId).eq("is_active", true);
  const idToPartNumber: Record<string, string> = {};
  for (const p of (partIdMap || [])) idToPartNumber[p.id] = p.part_number;

  const aliasesByPart: Record<string, string[]> = {};
  for (const a of aliases) {
    const pn = idToPartNumber[a.internal_part_id];
    if (!pn) continue;
    if (!aliasesByPart[pn]) aliasesByPart[pn] = [];
    const tag = a.mcp_sched_customers?.name ? `${a.customer_alias} [${a.mcp_sched_customers.name}]` : a.customer_alias;
    aliasesByPart[pn].push(tag);
  }

  // Limit context size — pick the parts that have at least one route step in this
  // category (so we don't send irrelevant noise) plus everything has aliases as
  // they help disambiguation.
  const partsInCategory = new Set<string>();
  for (const s of routeSteps) {
    if (s.op_type && s.op_type.toLowerCase() === category.toLowerCase()) {
      partsInCategory.add(s.part_number);
    }
  }
  // If filtering yields nothing (route steps don't have category info), keep all parts.
  const relevantParts = partsInCategory.size > 0
    ? parts.filter(p => partsInCategory.has(p.part_number))
    : parts;

  const partsBlock = relevantParts.map(p => {
    const steps = stepsByPart[p.part_number] || [];
    const stepsTxt = steps.length
      ? steps.map(s => `Op ${s.op_seq}${s.op_number ? "/"+s.op_number : ""} ${s.op_name || "?"}${s.op_type ? " ["+s.op_type+"]" : ""}`).join(" · ")
      : "(no route steps)";
    const aliasesTxt = aliasesByPart[p.part_number]?.length
      ? ` · aliases: ${aliasesByPart[p.part_number].join(", ")}`
      : "";
    return `  • ${p.part_number} — ${p.name}${aliasesTxt}\n      steps: ${stepsTxt}`;
  }).join("\n") || "  (no parts)";

  const dynamic = `MACHINES (category=${category}, ${machines.length}):
${machines.map(x => `  • ${x.code}${x.display_name ? " ("+x.display_name+")" : ""} — ${x.make || "?"} (${x.units?.name || "?"}, ${x.status})`).join("\n") || "  (none)"}

PARTS (${relevantParts.length}):
${partsBlock}

TRANSCRIPT:
"""
${transcript.trim()}
"""`;

  const a = await callClaude(STAGE_PROMPT, dynamic);
  const segments = Array.isArray((a as any)?.segments) ? (a as any).segments : [];
  return json({ extraction: { segments } });
}

async function callClaude(staticPrompt: string, dynamicPrompt: string): Promise<unknown> {
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
        { type: "text", text: staticPrompt, cache_control: { type: "ephemeral" } },
        { type: "text", text: dynamicPrompt },
      ],
      messages: [{ role: "user", content: "Extract." }],
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

  try { return JSON.parse(cleaned); }
  catch { throw new Error("claude returned invalid JSON: " + String(raw).slice(0, 200)); }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const ct = req.headers.get("content-type") || "";
    if (ct.includes("multipart/form-data")) return await transcribe(req);

    const supabase = createClient(SUPABASE_URL, SERVICE_KEY);
    const body = await req.json() as { transcript?: string; plant_id?: string; category?: string };
    if (!body.plant_id) throw new Error("plant_id is required");
    if (!body.transcript || !body.transcript.trim()) throw new Error("transcript is required");

    const category = (body.category || "pdc").toLowerCase();
    if (category === "pdc") return await extractPdc(supabase, body.plant_id, body.transcript);
    return await extractStage(supabase, body.plant_id, category, body.transcript);
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
