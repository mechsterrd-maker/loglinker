// loglinkr-chat — "Logi", the plant-scoped assistant for Loglinkr users.
// One round-trip: fetch the plant snapshot + Loglinkr platform docs, build
// system prompt, call Claude with prompt-cache marker on the static portion.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || Deno.env.get("ANON_KEY") || "";
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
// Cost optimisation: Haiku 4.5 for chat (vs Sonnet 4 previously). Same
// analytical quality for read-and-summarise workload; ~3-4× cheaper.
const MODEL         = "claude-haiku-4-5";
const AGENT         = "chat";
const DAILY_CAP_DEFAULT = 200;

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
HOW YOU THINK — operations consultant, not a data display
═══════════════════════════════════════════
You're a 25-year veteran manufacturing operations consultant inside the app.
Your job is NOT to recite numbers from the snapshot. It is to:
  1. SYNTHESIZE — connect dots across modules (NCRs ↔ calibration ↔ shots ↔ dies ↔ customers ↔ actions ↔ IATF docs)
  2. ANALYZE   — spot patterns (NCR trend this 30d vs prev 30d, breakdown hotspots, die-life curves, repeat reject reasons, audit gaps)
  3. PRIORITIZE — pick the SINGLE most impactful issue first; mention 1-2 supporting facts only
  4. RECOMMEND — end every non-trivial answer with a specific, named, doable next action

EXAMPLE — bad vs good answers
  ❌ BAD: "You have 5 open NCRs — 1 critical, 1 major, 3 minor."
  ✅ GOOD: "Acme's 737 cover dimensional variation is your top risk — critical, 4 days old, no root cause yet. It blocks a customer schedule. Start the 8D today and assign D2 to your QA head. (Quality tab)"

  ❌ BAD: "Calibration: 2 overdue, 1 due soon."
  ✅ GOOD: "MIC-12 micrometer is 36 days overdue — audit blocker, IATF 7.1.5.2. Any part measured with that gauge in the last 36 days is technically suspect. Quarantine those parts today and book the cal lab tomorrow. (Calibration tab)"

  ❌ BAD: "Reject rate is 1.95%."
  ✅ GOOD: "Reject is 1.95% — healthy overall. But ALL 12 rejects came from D-654-001 with cold-shut. Same die showed the porosity NCR last week. The cooling channel fix may need a follow-up check. (Production tab → Shots)"

═══════════════════════════════════════════
DATA YOU GET WITH EACH MESSAGE
═══════════════════════════════════════════
The dynamic block below contains TWO blobs:
- SNAPSHOT: module-by-module counts and recent items
- INSIGHTS: correlations + patterns (NCR trend, breakdown hotspots, die-life forecast, top reject reasons, action overdue, calibration risk, stock urgency, audit gaps, cash-flow risk)

USE BOTH. The insights blob is your raw material — extract the story from it.

═══════════════════════════════════════════
BEHAVIOR RULES
═══════════════════════════════════════════
1. Use ONLY the data below for facts. Never invent numbers.
2. If asked about another plant or company → politely decline (multi-tenant).
3. If asked for fine detail not in the snapshot ("list every NCR's full activity"), tell them which tab to open. Don't fabricate.
4. If asked "how do I X" → give exact navigation (e.g. "More → 📏 Calibration → '+ Add Instrument'").
5. Plain prose (no markdown headers, no asterisks, no tables). Short bullets only when listing concrete items.
6. Indian rupees: ₹2,63,740 / ₹2.64 L (lakhs ≥ 1L, crores ≥ 1Cr).
7. EVERY non-trivial answer ENDS with one specific named action + the tab to open it in.
8. If snapshot is empty for the asked module, say so honestly: "No records yet — add the first one under [path]."
9. Tone: senior advisor on the phone with a plant head. Direct, opinionated, no fluff.`;

// Returns separate snapshot + insights blocks so each can be cache_control'd.
// insights is skipped (null) when not needed — saves ~1.5k input tokens.
async function buildContext(
  supabase: ReturnType<typeof createClient>,
  plantId: string,
  wantsInsights: boolean,
) {
  const [snapRes, insRes] = await Promise.all([
    supabase.rpc("get_plant_snapshot", { p_plant_id: plantId }),
    wantsInsights
      ? supabase.rpc("get_plant_insights", { p_plant_id: plantId })
      : Promise.resolve({ data: null }),
  ]);
  if (snapRes.error) throw new Error("snapshot rpc: " + snapRes.error.message);

  // Compact JSON (no pretty-print) — saves ~40% chars vs indented.
  const snapshotBlock = `LIVE PLANT SNAPSHOT — THIS plant only\n${JSON.stringify(snapRes.data)}`;
  const insightsBlock = wantsInsights
    ? `LIVE INSIGHTS — correlations, trends, hotspots\n${JSON.stringify(insRes.data)}\n\nUse INSIGHTS for synthesis. End with one named action.`
    : "Only SNAPSHOT this turn. Ask 'biggest risks' / 'summary' for full analytical insights.";

  return { snapshotBlock, insightsBlock, snap: snapRes.data };
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

    // ─── Resolve user for usage tracking (auth optional but preferred) ────
    let userId: string | null = null;
    let dailyCap = DAILY_CAP_DEFAULT;
    const auth = req.headers.get("Authorization");
    if (auth && SUPABASE_ANON_KEY) {
      const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
        global: { headers: { Authorization: auth } },
      });
      const { data: { user } } = await userClient.auth.getUser();
      if (user) userId = user.id;
    }
    if (userId) {
      const { data: profile } = await supabase.from("users")
        .select("ai_daily_cap_per_user, plant_id")
        .eq("id", userId).maybeSingle();
      // Cap is set at plant level, not user level — pull from plants table
      const { data: pl } = await supabase.from("plants")
        .select("ai_daily_cap_per_user")
        .eq("id", body.plant_id).maybeSingle();
      dailyCap = (pl as any)?.ai_daily_cap_per_user ?? DAILY_CAP_DEFAULT;

      // ─── Pre-check daily cap (cheap; no API burnt) ────────────────────────
      const { data: usage } = await supabase
        .from("voice_usage_daily")
        .select("message_count")
        .eq("plant_id", body.plant_id).eq("user_id", userId)
        .eq("agent", AGENT).eq("day", new Date().toISOString().slice(0, 10))
        .maybeSingle();
      if (((usage as any)?.message_count ?? 0) >= dailyCap) {
        return new Response(JSON.stringify({
          response: `You've hit today's chat limit of ${dailyCap} messages. Plant_head can raise it in Plant settings → AI cap.`,
        }), { headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } });
      }
    }

    // ─── Cost knob: history slice 10 → 4 ──────────────────────────────────
    const history = (body.history || []).slice(-4);
    const messages: Msg[] = [...history, { role: "user", content: body.message }];

    // ─── Cost knob: only fetch insights when asked (or first turn) ────────
    const wantsInsights =
      history.length === 0 ||
      /\b(summary|summarise|summarize|overview|biggest|top|critical|priorit|important|worry|risk|issue|problem|how are we|how is|what.s wrong|today|this week|month|kya|enna|important|risks?|bottleneck)\b/i.test(body.message);

    const { snapshotBlock, insightsBlock } = await buildContext(supabase, body.plant_id, wantsInsights);

    const apiRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        // Cost knob: 1024 → 500. Plenty for chat.
        max_tokens: 500,
        // Cost knob: 3-block caching so static + snapshot get cache hits on
        // rapid follow-up turns. Insights changes per turn (or is skipped).
        system: [
          { type: "text", text: PLATFORM_DOC, cache_control: { type: "ephemeral" } },
          { type: "text", text: snapshotBlock, cache_control: { type: "ephemeral" } },
          { type: "text", text: insightsBlock },
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

    // ─── Log usage (best-effort, fire-and-forget) ─────────────────────────
    if (userId) {
      const u = data.usage || {};
      supabase.rpc("track_voice_usage", {
        p_plant_id: body.plant_id,
        p_user_id: userId,
        p_agent: AGENT,
        p_in: u.input_tokens || 0,
        p_out: u.output_tokens || 0,
        p_cache_read: u.cache_read_input_tokens || 0,
        p_cache_create: u.cache_creation_input_tokens || 0,
      }).then(() => {}).catch((e: Error) => console.warn("usage log failed:", e.message));
    }

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
