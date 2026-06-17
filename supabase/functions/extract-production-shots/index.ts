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

const STAGE_PROMPT = `You are an extraction engine for an Indian SME manufacturing plant's daily stage log.

INPUT: an English transcript translated by Whisper from a Tamil/Hindi/mixed voice dictation. Transcripts are often MESSY — missed words, no punctuation between segments, garbled part names, run-on sentences. Your job is to extract structured data anyway.

PRIMARY RULE — DO NOT LOSE SEGMENTS:
Every machine code mentioned in the transcript (e.g. "CNC 1", "CNC 2", "VMC 3", "machine 4") MUST produce ONE segment in your output. EVEN IF parts or operations are unclear or unintelligible, ALWAYS create the segment — set part_number=null / op_seq=null and the human will pick. It is FAR worse to lose a segment than to leave a field null.

EXTRACTION ALGORITHM:
1. Find every machine code mention in the transcript. Each one = one segment minimum.
2. For each machine, look at the surrounding text (until the next machine code or end of transcript) and extract:
   - qty_good: the first or most prominent number stated as production output ("2500 numbers", "two thousand pieces", "fifteen hundred").
   - qty_rejected: the number associated with words like "reject"/"rejection"/"scrap". Default to 0 if not stated.
   - reject_reason: short defect text after "rejection reason"/"because of"/"due to"/"reason". Examples: "blow", "gauge tight", "thread gauge problem", "finishing not good", "drill size oversize".
   - part_number: match operator's words against PARTS list (see LOOSE MATCHING below). Null if no plausible match.
   - op_seq + op_name: from route step (see OPERATION MAPPING). Null if ambiguous.
   - setup_change: true ONLY if "setup change" / "setting change" / "changeover" / "after setting" appears near this machine.

LOOSE PART MATCHING (apply aggressively):
- Word-stem match: "filter", "filtered", "filtering" ALL match any part containing "filter" (e.g. "Filter Head"). Same for "adapt"/"adapted" → "Adapter Plate", "cover"/"covered" → "Cover".
- Substring match: any word from the transcript that appears inside a part's name → match. "Tackle" might match "Tackle Plate" or be unclear.
- Customer/alias: "Bosch part" / "the Marvel one" → match any part whose aliases include that customer.
- Common abbreviations: "FH" → "Filter Head", "BP" → "Bottom Plate".
- If multiple parts plausibly match, prefer the one whose route includes the operation the operator named.
- If no part is plausibly named, set part_number=null and KEEP the segment.

OPERATION MAPPING:
- "first" / "1st" / "Op 1" / "Op 10" / "first stage" → SMALLEST op_seq for the matched part.
- "second" / "2nd" / "Op 2" / "Op 20" → next-smallest op_seq.
- "third" / "3rd" / "Op 3" / "Op 30" → next-smallest. Same pattern for 4th, 5th.
- Named ops ("facing", "drilling", "milling", "boring", "tapping", "tap"/"tapped") → match against op_name (substring/stem OK).
- If part has only ONE route step, use it.
- If ambiguous, set op_seq=null (don't skip the segment).

OUTPUT: strict JSON, NO markdown fences, NO commentary:
{
  "segments": [
    {
      "machine_code":  "exact code from MACHINES list, or null only if not in list",
      "part_number":   "exact part_number from PARTS list, or null",
      "op_seq":        <integer or null>,
      "op_name":       "exact op_name from part's route, or null",
      "qty_good":      <integer>,
      "qty_rejected":  <integer — default 0 if not stated>,
      "reject_reason": "short defect text, or null",
      "setup_change":  <boolean>,
      "confidence":    "high | medium | low — high when part+op match, medium when used loose matching, low when part/op null",
      "raw_quote":     "the exact transcript phrase this segment came from"
    }
  ]
}

HARD DON'Ts:
- DO NOT skip a segment because part or op is unclear. Set null and move on.
- DO NOT drop segments to "clean up" the output. Every machine mention = one segment.
- DO NOT invent qty_good when no number is stated near a machine.
- DO NOT include greetings / chatter / non-production sentences as segments.

Number words → integers ("two hundred forty"→240, "two thousand"→2000, "fifteen hundred"→1500).

If the transcript has ZERO machine mentions, return {"segments": []}.`;

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

  // Send ALL active parts — don't filter by category. Route step op_type is
  // often unset or named differently than the machine category, so filtering
  // here silently drops parts the operator would legitimately mention.
  // Haiku handles a few hundred parts fine; truncate only if extremely large.
  const MAX_PARTS = 250;
  const relevantParts = parts.slice(0, MAX_PARTS);

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
  const rawSegments = Array.isArray((a as any)?.segments) ? (a as any).segments : [];

  // SERVER-SIDE FUZZY FALLBACK
  // When the AI returns part_number=null but the operator clearly named
  // something, try a token-overlap match against the raw_quote. Same for
  // op_seq once we have a part — "1st"/"first"/"Op 10" → smallest op_seq, etc.
  const segments = rawSegments.map((s: any) => {
    if (!s.part_number && s.raw_quote) {
      const guess = fuzzyMatchPart(s.raw_quote, parts, aliasesByPart);
      if (guess) {
        s.part_number = guess;
        s.confidence = s.confidence === "high" ? "medium" : (s.confidence || "low");
      }
    }
    if (s.part_number && s.op_seq == null && s.raw_quote) {
      const partSteps = stepsByPart[s.part_number] || [];
      const guessSeq = fuzzyMatchOp(s.raw_quote, partSteps);
      if (guessSeq != null) {
        s.op_seq = guessSeq;
        const step = partSteps.find(ps => ps.op_seq === guessSeq);
        if (step) s.op_name = step.op_name;
      }
    }
    return s;
  });

  return json({ extraction: { segments } });
}

// Token-overlap match with light stemming. Operator says "filtered"
// (Whisper sometimes adds verb suffixes) → match "Filter Head". Strips
// common English suffixes (-ed, -ing, -s) before comparing.
function stemToken(t: string): string {
  if (t.length <= 4) return t;
  for (const suffix of ["ing", "ed", "es", "s"]) {
    if (t.endsWith(suffix) && t.length - suffix.length >= 3) return t.slice(0, -suffix.length);
  }
  return t;
}

function fuzzyMatchPart(
  raw: string,
  parts: Array<{ part_number: string; name: string }>,
  aliasesByPart: Record<string, string[]>,
): string | null {
  const stopwords = new Set([
    "the","a","an","for","on","at","in","of","to","and","or","is","was","were",
    "machine","cnc","vmc","lathe","press","good","reject","rejects","rejected",
    "rejection","setup","setting","change","operation","op","first","second",
    "third","fourth","fifth","1st","2nd","3rd","4th","5th","numbers","number",
    "pieces","pcs","after","then","also","completed","done","finished","reason",
    "also","blow","tight","died","gauge","gage","oversize","oversized","instead",
  ]);
  const tokens = raw
    .toLowerCase()
    .replace(/[^\w\s-]/g, " ")
    .split(/\s+/)
    .filter(t => t.length >= 3 && !stopwords.has(t) && !/^\d+$/.test(t))
    .map(stemToken);
  if (tokens.length === 0) return null;

  let best: { part_number: string; score: number } | null = null;
  for (const p of parts) {
    const hay = [
      p.part_number.toLowerCase(),
      p.name.toLowerCase(),
      ...(aliasesByPart[p.part_number] || []).map(a => a.toLowerCase()),
    ].join(" ");
    let score = 0;
    for (const t of tokens) {
      if (hay.includes(t)) score += t.length;
    }
    if (score > 0 && (!best || score > best.score)) {
      best = { part_number: p.part_number, score };
    }
  }
  return best && best.score >= 4 ? best.part_number : null;
}

// "1st"/"first"/"Op 1" → smallest op_seq; "2nd"/"second"/"Op 2" → next.
// Named ops ("facing", "drilling") → match against op_name.
function fuzzyMatchOp(
  raw: string,
  steps: Array<{ op_seq: number; op_name: string | null }>,
): number | null {
  if (steps.length === 0) return null;
  if (steps.length === 1) return steps[0].op_seq; // single route step — use it
  const sorted = [...steps].sort((a, b) => a.op_seq - b.op_seq);
  const lower = raw.toLowerCase();

  const ordinals: Array<[RegExp, number]> = [
    [/\b(first|1st|one\s*st|op\s*0?1\b|op\s*10\b|operation\s*1\b|operation\s*10\b|number\s*1\b|number\s*one\b)\b/, 0],
    [/\b(second|2nd|two\s*nd|op\s*0?2\b|op\s*20\b|operation\s*2\b|operation\s*20\b|number\s*2\b|number\s*two\b)\b/, 1],
    [/\b(third|3rd|three\s*rd|op\s*0?3\b|op\s*30\b|operation\s*3\b|operation\s*30\b|number\s*3\b|number\s*three\b)\b/, 2],
    [/\b(fourth|4th|op\s*0?4\b|op\s*40\b|operation\s*4\b|operation\s*40\b)\b/, 3],
    [/\b(fifth|5th|op\s*0?5\b|op\s*50\b|operation\s*5\b|operation\s*50\b)\b/, 4],
  ];
  for (const [re, idx] of ordinals) {
    if (re.test(lower) && sorted[idx]) return sorted[idx].op_seq;
  }

  // Named op match
  for (const s of sorted) {
    if (s.op_name && lower.includes(s.op_name.toLowerCase())) return s.op_seq;
  }
  return null;
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
