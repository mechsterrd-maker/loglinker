// loglinkr-voice-entry — multilingual voice-driven data entry orchestrator.
//
// Architecture:
//   Browser does the speech-to-text (free, on-device) and sends us the
//   transcript. We pass it to Claude with a module-specific system prompt
//   that knows which fields to collect. Claude returns the next question
//   (in the operator's detected language) or — when all required fields
//   are collected and the operator has confirmed — a ready_to_save flag
//   plus the structured payload. The client then performs the actual
//   database insert.
//
// Per-turn cost: ~₹1-2 with Claude Sonnet 4 prompt caching. Whole
// breakdown entry typically 3-4 turns = ~₹5 total.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL         = "claude-sonnet-4-20250514";

// =============================================================================
// MODULE REGISTRY — each entry defines: which fields to collect + which Claude
// system prompt to use. Adding a new module = adding an entry here (and a
// matching `intent` branch in the client-side save handler).
// =============================================================================
const MODULES: Record<string, { title: string; instructions: string }> = {

  maintenance_breakdown: {
    title: "Maintenance Breakdown",
    instructions: `You are helping a maintenance operator log a machine breakdown by voice.

FIELDS TO COLLECT (one at a time, in order):
  • machine_code        (string, REQUIRED)   "Which machine? / Enna machine? / Konsa machine?"
  • description         (string, REQUIRED)   "What's the problem? / Yenna problem? / Kya hua?"
  • production_stopped  (boolean, OPTIONAL)  "Is production stopped? / Production stop aagacha?"
  • estimated_downtime_minutes (number, OPTIONAL)  "How long to fix? / Yetra neram?"
  • severity            (enum: minor|major|critical, OPTIONAL — infer if not given)

INFERENCE RULES:
- severity=critical → production stopped + safety risk (oil leak, electrical, gas)
- severity=major    → production stopped, no safety risk
- severity=minor    → degraded performance, line still running

If operator says everything in one sentence (e.g. "PDC-150 oil leak heavily, line stopped 30 min"),
fill all fields you can extract — don't re-ask what was already said.`,
  },

  shot_log: {
    title: "Production Shot Log",
    instructions: `You are helping a production operator log a shot count by voice (typically at shift-end or mid-shift).

FIELDS TO COLLECT (one at a time):
  • machine_code      (string, REQUIRED)   "Which machine? / Enna machine?"
  • die_code          (string, REQUIRED)   "Which die? / Enna die?"
  • shots_good        (number, REQUIRED)   "How many good? / Yetra good?"
  • shots_rejected    (number, REQUIRED)   "How many rejects? / Yetra reject?"
  • reject_reason     (string, REQUIRED IF shots_rejected > 0)  "What was the reject reason? / Reject reason yenna?"
  • shift_name        (string, OPTIONAL — try to infer from time-of-day in context, else ask)
  • metal_consumed_kg (number, OPTIONAL — only ask if operator volunteered it)

INFERENCE RULES:
- If operator says "300 nallavum, 12 rejecta poruchchu, flash problem" → shots_good=300, shots_rejected=12, reject_reason="flash"
- If they say "no rejects" / "all good" / "zero reject" → shots_rejected=0, skip reject_reason
- Die code patterns: D-XXX-NNN (e.g. D-654-001). Be flexible — operator may say just "654 die".
- Match die_code against the dies list in plant context; pick the best match.

DON'T ASK about operator name — we use the logged-in user.`,
  },

  ncr_raise: {
    title: "NCR (Non-Conformance Report)",
    instructions: `You are helping a QA / supervisor raise an NCR (non-conformance report) by voice.

FIELDS TO COLLECT (one at a time):
  • source         (enum, REQUIRED) — one of:
                     in_process | customer_complaint | audit_finding | supplier | other
                     Infer from context if obvious (e.g. "Acme customer complained" → customer_complaint).
                     Else ask: "Yenga irundhu vandhuchu? / Where did this issue come from?"
  • title          (string, REQUIRED)  short headline (max 80 chars) — "Briefly what is the issue?"
  • severity       (enum: minor|major|critical, REQUIRED — infer if obvious)
                     - critical: customer stopped line / safety / huge cost
                     - major: customer-impacting OR batch-level rejection
                     - minor: in-process anomaly, contained
  • description    (string, REQUIRED)  fuller description — "Tell me more detail"
  • part_number    (string, OPTIONAL) — "Which part? / Enna part?"
  • qty_affected   (number, OPTIONAL) — "How many affected? / Yetra parts?"

After collecting, summarise: "NCR raise pannava? <source> · <severity> · <title> · qty <X>"`,
  },

  stock_issue: {
    title: "Stock Issue (Material Out)",
    instructions: `You are helping a stores operator issue stock to production by voice.

FIELDS TO COLLECT (one at a time):
  • item_code       (string, REQUIRED)  match against plant's stock items list — "Which item? / Enna item?"
                    Operator may speak just the name (e.g. "M8 bolts", "die lubricant").
                    Match flexibly against the item list provided in plant context.
  • qty             (number, REQUIRED)  "How many / how much? / Yetra qty?"
  • reference       (string, OPTIONAL)  "Issued to which line / machine / job? / Yenga ku?"
  • notes           (string, OPTIONAL)  any extra context

INFERENCE RULES:
- If operator says "200 M8 bolts assembly line ku" → item="HW-BOLT-M8" (match), qty=200, reference="assembly line".
- UOM is part of the item master — don't ask UOM separately; just use qty.

After collecting, summarise with stock item's CODE and NAME from the master.`,
  },
};

const SYSTEM_PROMPT_COMMON = `You are "Logi", the voice-entry assistant inside Loglinkr — an audit-ready ERP for Indian SME manufacturers.

CRITICAL LANGUAGE RULE:
- Operators speak Tamil, Hindi, Telugu, Kannada, Marathi, English, or "Tanglish" / "Hinglish" (code-switched English-Indian).
- DETECT the language from the operator's latest message.
- ALWAYS REPLY IN THE EXACT SAME LANGUAGE/STYLE. If they used Tamil-English mix, reply in Tamil-English mix. If pure Tamil, pure Tamil. If pure English, English.
- Use Tamil script for Tamil words, Devanagari for pure Hindi. Use Latin script for Tanglish/Hinglish (operators read those easier on phone).

CONVERSATION STYLE:
- Be brief and friendly. Like an experienced shift-supervisor checking in.
- Ask ONE field at a time. Don't dump a survey.
- After each answer, ACK briefly (one or two words) then ask next.
- If the operator says multiple facts in one message, extract them all — don't re-ask.
- If they correct themselves mid-conversation ("no wait, machine PDC-250"), update the field and continue.
- When all REQUIRED fields are collected, generate a clear summary in their language and ask them to confirm ("Confirm pannava? / Save karein? / Should I save?").

BOOTSTRAP: If you receive the message "(start)", greet briefly and ask for the FIRST required field. Pick the language randomly from {Tanglish, English} for the opener — the operator will switch to their preferred language in their next reply and you must follow.

OUTPUT FORMAT — STRICT JSON, NOTHING OUTSIDE THE BRACES, NO MARKDOWN FENCES:
{
  "language": "ta|hi|te|kn|mr|en|ta-en|hi-en",
  "fields": { ...everything collected so far, as a flat object... },
  "machine_code_match": "exact machine code if matched against the plant's machines, else null",
  "next_question": "your reply text in the operator's language (this is what we show + speak back)",
  "is_complete": false,
  "ready_to_save": false
}

STATE MACHINE:
- While collecting fields → is_complete=false, ready_to_save=false, next_question=next question or correction
- When all required fields are in AND you've summarized → is_complete=true, ready_to_save=false, next_question=summary text + "Confirm pannava?"
- When operator confirms (yes / aamaa / haan / save pannunga / sari) → is_complete=true, ready_to_save=true, next_question=brief success acknowledgement
- If operator wants to edit ("no wait", "edit", "rendraavadhu pannungal") → is_complete=false, ready_to_save=false, ask which field to change`;

async function buildSystemPrompt(
  supabase: ReturnType<typeof createClient>,
  plantId: string,
  moduleKey: string,
) {
  const mod = MODULES[moduleKey];
  if (!mod) throw new Error("Unknown module: " + moduleKey);

  // Module-specific context (e.g. list of available machines for breakdown entry)
  let contextBlock = "";
  const now = new Date();
  const localHour = (now.getUTCHours() + 5) % 24; // IST rough
  contextBlock += `\nCURRENT IST TIME: approx ${localHour}:${String((now.getUTCMinutes() + 30) % 60).padStart(2,"0")} — use this to infer shift if not stated.\n`;

  if (moduleKey === "maintenance_breakdown") {
    const { data: machines } = await supabase
      .from("machines").select("code, make, model, category, status, unit_id, units(name)")
      .eq("plant_id", plantId);
    const lines = (machines || []).map((m: any) =>
      `  • ${m.code} — ${m.make || "?"}${m.model ? " " + m.model : ""} (${m.category}, ${m.units?.name || "?"}, ${m.status})`
    );
    contextBlock += `\nMACHINES AVAILABLE:\n${lines.join("\n") || "  (none configured)"}\n`;
  }

  if (moduleKey === "shot_log") {
    const [m, d, sh] = await Promise.all([
      supabase.from("machines").select("code, make, category, status, units(name)").eq("plant_id", plantId).eq("category", "pdc"),
      supabase.from("mcp_pdc_dies").select("code, part_number, customer_name, status, current_stroke_count, max_strokes").eq("plant_id", plantId).neq("status", "retired"),
      supabase.from("shifts").select("name, start_time, end_time").eq("plant_id", plantId).eq("is_active", true),
    ]);
    contextBlock += `\nPDC MACHINES:\n${(m.data || []).map((x: any) => `  • ${x.code} — ${x.make || "?"} (${x.units?.name || "?"}, ${x.status})`).join("\n") || "  (none)"}\n`;
    contextBlock += `\nDIES AVAILABLE:\n${(d.data || []).map((x: any) => `  • ${x.code} (part ${x.part_number}${x.customer_name ? ", " + x.customer_name : ""}, ${x.current_stroke_count?.toLocaleString("en-IN") || 0}/${x.max_strokes?.toLocaleString("en-IN") || 0} strokes)`).join("\n") || "  (none)"}\n`;
    contextBlock += `\nSHIFTS:\n${(sh.data || []).map((x: any) => `  • "${x.name}" — ${x.start_time}–${x.end_time}`).join("\n") || "  (none)"}\n`;
  }

  if (moduleKey === "ncr_raise") {
    const { data: parts } = await supabase
      .from("mcp_pdc_parts").select("part_number, name").eq("plant_id", plantId).limit(50);
    const lines = (parts || []).map((p: any) => `  • ${p.part_number} — ${p.name}`);
    contextBlock += `\nPARTS:\n${lines.join("\n") || "  (none — accept whatever part number operator says)"}\n`;
  }

  if (moduleKey === "stock_issue") {
    const { data: items } = await supabase
      .from("mcp_stocks_items").select("code, name, category, uom, current_qty").eq("plant_id", plantId).order("name");
    const lines = (items || []).map((i: any) => `  • ${i.code} — ${i.name} (${i.category || "?"}, current: ${i.current_qty} ${i.uom})`);
    contextBlock += `\nSTOCK ITEMS AVAILABLE:\n${lines.join("\n") || "  (none)"}\n`;
  }

  // Static portion (cacheable) + dynamic (per-call) split
  const staticDoc = `${SYSTEM_PROMPT_COMMON}

==========================
MODULE: ${mod.title}
==========================
${mod.instructions}`;

  const dynamicDoc = `==========================
LIVE PLANT CONTEXT for THIS conversation
==========================${contextBlock}`;

  return { staticDoc, dynamicDoc };
}

interface Msg { role: "user" | "assistant"; content: string }

function safeJsonParse(s: string): unknown {
  let cleaned = s.trim();
  const fence = cleaned.match(/^```(?:json)?\s*\n?([\s\S]*?)\n?```$/);
  if (fence) cleaned = fence[1].trim();
  const start = cleaned.indexOf("{");
  const end = cleaned.lastIndexOf("}");
  if (start !== -1 && end !== -1) cleaned = cleaned.slice(start, end + 1);
  return JSON.parse(cleaned);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
      },
    });
  }

  try {
    const supabase = createClient(SUPABASE_URL, SERVICE_KEY);
    const body = await req.json() as {
      plant_id: string;
      module: string;
      transcript?: string;
      state?: { history?: Msg[] };
    };

    if (!body.plant_id) throw new Error("plant_id is required");
    if (!body.module) throw new Error("module is required");
    if (!MODULES[body.module]) throw new Error("unknown module: " + body.module);

    const { staticDoc, dynamicDoc } = await buildSystemPrompt(supabase, body.plant_id, body.module);

    // Build conversation history
    const history = body.state?.history ?? [];
    const userMsg = body.transcript?.trim() || "(start)";
    const messages: Msg[] = [...history, { role: "user", content: userMsg }];

    const apiRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 600,
        system: [
          { type: "text", text: staticDoc, cache_control: { type: "ephemeral" } },
          { type: "text", text: dynamicDoc },
        ],
        messages,
      }),
    });

    if (!apiRes.ok) {
      const t = await apiRes.text();
      throw new Error(`Anthropic ${apiRes.status}: ${t.slice(0, 400)}`);
    }
    const data = await apiRes.json();
    const rawText = data.content
      ?.filter((b: { type: string }) => b.type === "text")
      ?.map((b: { text: string }) => b.text)
      ?.join("\n") ?? "";

    let parsed: any;
    try { parsed = safeJsonParse(rawText); }
    catch (_e) {
      throw new Error("Model returned non-JSON: " + rawText.slice(0, 200));
    }

    // Updated history INCLUDES this turn so the next request continues seamlessly
    const updatedHistory: Msg[] = [...messages, { role: "assistant", content: rawText }];

    return new Response(JSON.stringify({
      language: parsed.language ?? "en",
      fields: parsed.fields ?? {},
      machine_code_match: parsed.machine_code_match ?? null,
      next_question: parsed.next_question ?? "",
      is_complete: !!parsed.is_complete,
      ready_to_save: !!parsed.ready_to_save,
      state: { history: updatedHistory },
      usage: data.usage,
    }), {
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
    });
  } catch (err) {
    const e = err as Error;
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
    });
  }
});
