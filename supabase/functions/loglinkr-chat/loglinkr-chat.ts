// loglinkr-chat — "Logi", the plant-scoped assistant for Loglinkr users.
// One round-trip: fetch the plant snapshot + Loglinkr platform docs, build
// system prompt, call Claude with prompt-cache marker on the static portion.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL         = "claude-sonnet-4-20250514";

// Static portion of the system prompt — cached by Anthropic to cut input cost.
const PLATFORM_DOC = `You are "Logi", the AI assistant inside Loglinkr — an audit-ready ERP for SME manufacturers (mainly IATF 16949 certified plants).

You answer plant operators, supervisors, plant heads, QA engineers. Keep answers concise, practical, action-oriented.

═══════════════════════════════════════════
LOGLINKR PLATFORM — MODULES & NAVIGATION
═══════════════════════════════════════════

Main bottom-tab + top-nav modules (visible on every screen):
• Home — plant overview, KPIs, recent activity
• Production — log shots, machines, dies, parts, routes; tracks reject %, die strokes
• Quality — NCR (non-conformance) register, severity, root cause, corrective action
• Chat — group chats. Drop a photo of a DC/invoice → AI auto-extracts to Documents.
• More — gateway to every other module

Under "More":
• 🛡 IATF 16949 · Audit Readiness — all 52 mandatory docs, status (approved / stale / draft / missing), readiness %, owner, review cadence
• 📏 Calibration Register (IATF 7.1.5.2) — instruments + calibration history + due / overdue alerts. Cascade: out-of-tolerance cal → auto-action for QA to quarantine parts inspected since last good cal.
• 🎓 Training Matrix (IATF 7.2) — skills + per-employee training records with validity. Two sub-tabs: Records (matrix) + Skill Master.
• 📅 Customer Schedules — plan vs supply per customer per month
• 🔀 Movements — material in/out flow
• 🔍 Trace · Audit Investigation — linked timeline by date / part / machine
• 📑 Reports & IATF Documents — generate printable audit-ready reports
• 👥 People — units, team, shifts
• 🔧 Maintenance — breakdowns, machine status
• 📦 Stocks — inventory, items, transactions
• ✓ Action Hub — all open commitments across sources (NCR, audit, customer, manual, MOM, etc.)
• 📄 Documents · Bills — invoices, DCs, payments, vendors

KEY TERMS:
• Plant = top-level tenant (your company)
• Unit = physical location within a plant
• Shift = work shift (typical A/B/C)
• NCR = Non-Conformance Report
• CAPA = Corrective + Preventive Action
• GRN = Goods Receipt Note (when material arrives)
• DC = Delivery Challan (material moves without invoice)
• Jobwork = subcontracted operation (material sent out, comes back)
• PDC = Pressure Die Casting
• PPAP = Production Part Approval Process
• PFMEA / DFMEA = Process / Design Failure Mode + Effects Analysis

CHAT-TRANSPORT AI (for the "# Transport" group):
• Photo of any DC / invoice → server extracts via Claude vision (Sonnet 4)
• Auto-rotates rotated phone shots, falls back to high-res image when first pass is low-confidence
• Server cross-checks "seller is us vs buyer is us" so direction can't be flipped
• Result lands in Documents → user can verify + push to stock (GRN flow)

DATA CASCADES (everything is linked):
• Shot logged with reject % > 3% → auto-raises NCR
• GRN received short by > 5% → auto-NCR + vendor follow-up action
• Out-of-tolerance calibration → auto-action for QA
• Training expiring → action for skill renewal
• Jobwork DC out → tracked in Returnables tab; jobwork DC in → matches + closes
• Inter-unit DC → tracked in In-Transit tab
• Doc deletion → cascade-protects history via audit_log

ROLES & RLS:
• Every user belongs to ONE plant.
• Roles: plant_head, admin, supervisor, qa, operator, store, driver, toolroom
• All data is plant-scoped (you can never see another plant's data).

═══════════════════════════════════════════
BEHAVIOR RULES
═══════════════════════════════════════════
1. Use ONLY the live plant snapshot (below) for facts about *this* plant. Never invent numbers.
2. If asked about another plant or company → politely decline (multi-tenant: each plant only sees its own data).
3. If asked something that isn't in the snapshot (e.g. "list every NCR with full details"), tell the user where in the UI to look — don't make up the answer.
4. If asked "how do I X" → give exact navigation (e.g. "More → 📏 Calibration → '+ Add Instrument'").
5. Be concise. Use bullet points. Plain prose, not markdown formatting that won't render in chat (no **bold**, no headers).
6. Format Indian-style for rupee amounts (₹2,63,740 / ₹2.64 L for 2.64 lakhs). Use lakhs for ≥ 1L, crores for ≥ 1Cr.
7. Always end with a useful follow-up question OR a suggested action when there's clear next-step value.
8. Cite the module: "(source: Quality tab)" so the user can drill in.
9. If snapshot shows zero records for the asked module, gently nudge: "No data yet — add the first one under [path]."
10. Tone: friendly + practical. Like a plant supervisor who knows the system. Not a help bot.`;

async function buildSystemPrompt(supabase: ReturnType<typeof createClient>, plantId: string) {
  const { data: snap, error } = await supabase.rpc("get_plant_snapshot", { p_plant_id: plantId });
  if (error) throw new Error("snapshot rpc: " + error.message);

  const dynamicBlock = `═══════════════════════════════════════════
LIVE PLANT SNAPSHOT — THIS plant only, refreshed for this conversation
═══════════════════════════════════════════

${JSON.stringify(snap, null, 2)}

═══════════════════════════════════════════
RESPOND TO THE USER NOW
═══════════════════════════════════════════`;

  return { staticDoc: PLATFORM_DOC, dynamicBlock, snap };
}

interface Msg { role: "user" | "assistant"; content: string }

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
      message: string;
      history?: Msg[];
      plant_id: string;
    };

    if (!body.plant_id) throw new Error("plant_id is required");
    if (!body.message) throw new Error("message is required");

    const { staticDoc, dynamicBlock } = await buildSystemPrompt(supabase, body.plant_id);

    // Trim history to last ~10 turns to keep token budget sane
    const history = (body.history || []).slice(-10);

    const messages: Msg[] = [...history, { role: "user", content: body.message }];

    const apiRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 1024,
        // Split system into static (cacheable) + dynamic (per-call). Saves 90%
        // input cost on the platform docs over a multi-turn chat.
        system: [
          { type: "text", text: staticDoc, cache_control: { type: "ephemeral" } },
          { type: "text", text: dynamicBlock },
        ],
        messages,
      }),
    });

    if (!apiRes.ok) {
      const t = await apiRes.text();
      throw new Error(`Anthropic ${apiRes.status}: ${t.slice(0, 400)}`);
    }
    const data = await apiRes.json();
    const text = data.content
      ?.filter((b: { type: string }) => b.type === "text")
      ?.map((b: { text: string }) => b.text)
      ?.join("\n") ?? "";

    return new Response(JSON.stringify({
      response: text,
      usage: data.usage,
      stop_reason: data.stop_reason,
    }), {
      headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
    });
  } catch (err) {
    const e = err as Error;
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
    });
  }
});
