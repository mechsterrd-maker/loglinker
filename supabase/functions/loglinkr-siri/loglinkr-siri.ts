// loglinkr-siri — voice-first manager assistant.
// MANAGER-ONLY (plant_head | admin). Read + navigate only — NO writes.
// Tool-use enabled: search_documents, read_iatf_doc, query_open_items,
// read_kpis, navigate. Returns a structured nav hint the client renders
// as a tap-to-open button.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || Deno.env.get("ANON_KEY") || "";
const SERVICE_KEY       = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY     = Deno.env.get("ANTHROPIC_API_KEY")!;
// Cost optimisation: Haiku 4.5 is plenty smart for "read snapshot + insights,
// answer like a consultant" — and ~3-4× cheaper than Sonnet 4. The model
// quality difference for this workload is negligible.
const MODEL             = "claude-haiku-4-5";
const AGENT             = "siri";
const DAILY_CAP_DEFAULT = 200;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// =============================================================================
// TOOLS — read-only + nav. Schemas Claude sees + how we execute each.
// =============================================================================
const TOOLS = [
  {
    name: "search_documents",
    description: "Search the plant's records across IATF docs, NCRs, logistics docs, breakdowns, and actions. Use when the manager asks about a specific document, NCR number, vendor name, machine code, etc.",
    input_schema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Search term (code, title, keyword, vendor name, NCR number)" },
        kind: {
          type: "string",
          enum: ["all", "iatf", "ncr", "logistics", "breakdown", "action", "instrument"],
          description: "Limit search to one record type. Default 'all'.",
        },
      },
      required: ["query"],
    },
  },
  {
    name: "read_iatf_doc",
    description: "Read details of a specific IATF document by its code (e.g. CAL-001, TR-001, NCR-LOG, PFD-001). Returns title, status, owner, review date, IATF clauses, and a count of live records backing it.",
    input_schema: {
      type: "object",
      properties: {
        doc_code: { type: "string", description: "Exact IATF doc code, e.g. CAL-001" },
      },
      required: ["doc_code"],
    },
  },
  {
    name: "query_open_items",
    description: "Count and list open / overdue items in a module. Use for 'how many open ___' or 'show me overdue ___'.",
    input_schema: {
      type: "object",
      properties: {
        module: {
          type: "string",
          enum: ["ncrs", "actions", "breakdowns", "calibrations_due", "training_expiring", "iatf_stale"],
        },
        limit: { type: "number", description: "Max items to return (default 5)" },
      },
      required: ["module"],
    },
  },
  {
    name: "read_kpis",
    description: "Read the plant's full live KPI snapshot — counts across every module, recent NCRs, calibrations due, IATF readiness %, payables, etc. Use for 'summary' / 'overview' / 'how is the plant'.",
    input_schema: { type: "object", properties: {} },
  },
  {
    name: "navigate",
    description: "Signal the UI to open a tab or specific record. ALWAYS call this after answering about a specific document/record so the manager can tap to open it. NEVER skip when you've identified a navigable target.",
    input_schema: {
      type: "object",
      properties: {
        tab: {
          type: "string",
          enum: [
            "home", "production", "quality", "maintenance", "stocks", "actions",
            "documents", "schedules", "movements", "trace", "reports",
            "people", "iatf", "calibration", "training",
          ],
          description: "Which top-level tab to open.",
        },
        record_id: { type: "string", description: "Optional record ID to highlight" },
        search: { type: "string", description: "Optional pre-fill search term" },
        doc_code: { type: "string", description: "Optional IATF doc code to highlight" },
      },
      required: ["tab"],
    },
  },
];

const SYSTEM_PROMPT = `You are "Logi", a 25-year-veteran manufacturing operations consultant inside Loglinkr — an audit-ready ERP for IATF 16949 plants. You're advising a manager (plant_head / admin) who is walking the shop floor and asks you questions by voice.

═══════════════════════════════════════════════════════
YOUR JOB IS NOT TO RECITE NUMBERS. YOUR JOB IS TO:
═══════════════════════════════════════════════════════
1. SYNTHESIZE  — connect dots across modules (e.g. "the calibration that's 36 days overdue is on the vernier used to inspect the batch that triggered NCR-DEMO-002")
2. ANALYZE     — spot patterns (recurring breakdowns, NCR trend, repeat reject reasons, die life curves, audit gaps)
3. PRIORITIZE  — pick the SINGLE biggest issue first; mention 1-2 supporting facts only
4. RECOMMEND   — end every answer with a specific, named, doable next action

────────────────────────────────────────────────────────
EXAMPLES — bad vs good answers
────────────────────────────────────────────────────────
❌ BAD: "You have 5 open NCRs — 1 critical, 1 major, 3 minor."

✅ GOOD: "Acme's 737 cover dimensional variation is the top risk — critical, 4 days old, no root cause yet. It blocks a customer schedule and there's a Monday review. Start the 8D now and assign D2 to the QA head. Want me to open it?"

❌ BAD: "Calibration: 2 overdue, 1 due soon."

✅ GOOD: "MIC-12 micrometer is 36 days overdue on calibration — that's an audit blocker, IATF clause 7.1.5.2. Any part measured with that gauge in the last 36 days is technically suspect. Quarantine those parts today and book the lab for tomorrow. Tap to open Calibration."

❌ BAD: "Reject rate is 1.95% this month."

✅ GOOD: "Reject is 1.95% — that's healthy. But all 12 of your rejects came from D-654-001 with cold-shut. Same die showed the porosity NCR last week. The cooling channel fix you did may need a follow-up. Tap to open the NCR."

────────────────────────────────────────────────────────
THE LIVE PLANT DATA YOU GET
────────────────────────────────────────────────────────
With every message you receive a fresh snapshot:
- get_plant_snapshot:  module-by-module counts and recent items
- get_plant_insights:  CORRELATIONS — NCR trend (this 30d vs prev 30d), breakdown hotspots (machines with ≥2 in 90d), production reject_pct trend, worst die, top reject reasons, die-life forecast (≥75% used), action overdue, calibration overdue with days, stock urgency, cash-flow risk, returnables aging, audit gaps with stale doc list.

USE BOTH. The insights blob is your raw material — extract the story.

────────────────────────────────────────────────────────
RULES
────────────────────────────────────────────────────────
1. READ-ONLY. You cannot create, update, or delete. If asked to write, say: "I can't make entries from here — open the form or use voice entry. But I can tell you what to look for."

2. LANGUAGE — detect from the user message and reply in the SAME language exactly. Tamil, Hindi, English, Tanglish, Hinglish. Switch when they switch.

3. VOICE-FIRST OUTPUT — this gets spoken aloud:
   - Short sentences. No markdown, no headers, no bullet points, no asterisks.
   - Avoid lists; pick ONE thing.
   - Numbers: small in words ("two NCRs"), large in digits ("2.6 lakh rupees").
   - Don't recite raw JSON or table data.

4. TOOL USE:
   - ALWAYS call \`navigate\` when your answer is about a specific document, module, or record. The UI shows a tap-to-open button.
   - Use \`read_kpis\` only if you need to refresh the snapshot mid-conversation.
   - Use \`query_open_items\` only if you need the detailed item list beyond what's in the snapshot.
   - Use \`search_documents\` / \`read_iatf_doc\` for specific code/name lookups.

5. NEVER fabricate. If insights show zero records, say so honestly and stop. Don't pad.

6. EVERY ANSWER ENDS WITH:
   - One named, specific next action ("Start the 8D" / "Call Cosmos Plating" / "Book the cal lab" / "Approve the OC-001 review")
   - A navigation hint via the navigate tool

You're the manager's senior advisor on the shop floor. They trust you to cut through the noise and tell them the ONE thing that matters most right now.`;

// =============================================================================
// TOOL EXECUTION
// =============================================================================
async function executeTool(
  supabase: ReturnType<typeof createClient>,
  plantId: string,
  name: string,
  args: any,
): Promise<unknown> {
  if (name === "search_documents") {
    const q = (args.query || "").trim();
    const kind = args.kind || "all";
    const results: any[] = [];

    if (kind === "all" || kind === "iatf") {
      const { data } = await supabase
        .from("v_iatf_audit_readiness")
        .select("doc_code, title, doc_status, source_view_name, days_to_review")
        .eq("plant_id", plantId)
        .or(`doc_code.ilike.%${q}%,title.ilike.%${q}%`)
        .limit(5);
      results.push(...((data as any[]) || []).map((d) => ({ kind: "iatf", ...d })));
    }
    if (kind === "all" || kind === "ncr") {
      const { data } = await supabase
        .from("mcp_quality_ncrs")
        .select("id, ncr_number, title, severity, status, source")
        .eq("plant_id", plantId)
        .or(`ncr_number.ilike.%${q}%,title.ilike.%${q}%`)
        .limit(5);
      results.push(...((data as any[]) || []).map((n) => ({ kind: "ncr", ...n })));
    }
    if (kind === "all" || kind === "logistics") {
      const { data } = await supabase
        .from("mcp_logistics_documents")
        .select("id, doc_number, doc_type, vendor_name_raw, doc_date, status, total_value")
        .eq("plant_id", plantId)
        .or(`doc_number.ilike.%${q}%,vendor_name_raw.ilike.%${q}%`)
        .limit(5);
      results.push(...((data as any[]) || []).map((d) => ({ kind: "logistics_doc", ...d })));
    }
    if (kind === "all" || kind === "breakdown") {
      const { data } = await supabase
        .from("mcp_maintenance_breakdowns")
        .select("id, description, status, reported_at, machine_id, machines(code)")
        .eq("plant_id", plantId)
        .or(`description.ilike.%${q}%`)
        .limit(5);
      results.push(...((data as any[]) || []).map((b) => ({ kind: "breakdown", ...b })));
    }
    if (kind === "all" || kind === "action") {
      const { data } = await supabase
        .from("actions")
        .select("id, title, source_type, status, due_at, department")
        .eq("plant_id", plantId)
        .ilike("title", `%${q}%`)
        .limit(5);
      results.push(...((data as any[]) || []).map((a) => ({ kind: "action", ...a })));
    }
    if (kind === "all" || kind === "instrument") {
      const { data } = await supabase
        .from("v_iatf_calibration_register")
        .select("record_id, instrument_code, name, status, due_status, days_to_due")
        .eq("plant_id", plantId)
        .or(`instrument_code.ilike.%${q}%,name.ilike.%${q}%`)
        .limit(5);
      results.push(...((data as any[]) || []).map((i) => ({ kind: "instrument", ...i })));
    }
    return { found: results.length, results };
  }

  if (name === "read_iatf_doc") {
    const { data } = await supabase
      .from("v_iatf_audit_readiness")
      .select("*")
      .eq("plant_id", plantId)
      .ilike("doc_code", args.doc_code)
      .maybeSingle();
    if (!data) return { error: "Document not found: " + args.doc_code };
    let recordCount: number | null = null;
    const viewName = (data as any).source_view_name;
    if (viewName) {
      try {
        const { count } = await supabase
          .from(viewName)
          .select("*", { count: "exact", head: true })
          .eq("plant_id", plantId);
        recordCount = count || 0;
      } catch {}
    }
    return { ...data, record_count: recordCount };
  }

  if (name === "query_open_items") {
    const module = args.module;
    const limit = Math.min(args.limit || 5, 20);

    if (module === "ncrs") {
      const { data, count } = await supabase
        .from("mcp_quality_ncrs")
        .select("id, ncr_number, title, severity, status", { count: "exact" })
        .eq("plant_id", plantId)
        .not("status", "in", "(closed,cancelled)")
        .order("severity", { ascending: false })
        .limit(limit);
      return { total: count, items: data };
    }
    if (module === "actions") {
      const { data, count } = await supabase
        .from("actions")
        .select("id, title, source_type, status, due_at, department", { count: "exact" })
        .eq("plant_id", plantId)
        .in("status", ["open", "in_progress"])
        .order("due_at", { ascending: true, nullsFirst: false })
        .limit(limit);
      return { total: count, items: data };
    }
    if (module === "breakdowns") {
      const { data, count } = await supabase
        .from("mcp_maintenance_breakdowns")
        .select("id, description, status, reported_at, machine_id, machines(code)", { count: "exact" })
        .eq("plant_id", plantId)
        .in("status", ["open", "attended"])
        .order("reported_at", { ascending: false })
        .limit(limit);
      return { total: count, items: data };
    }
    if (module === "calibrations_due") {
      const cutoff = new Date(Date.now() + 30 * 86400000).toISOString().slice(0, 10);
      const { data, count } = await supabase
        .from("v_iatf_calibration_register")
        .select("record_id, instrument_code, name, due_status, days_to_due", { count: "exact" })
        .eq("plant_id", plantId)
        .in("due_status", ["overdue", "due_soon"])
        .order("days_to_due", { ascending: true })
        .limit(limit);
      return { total: count, items: data };
    }
    if (module === "training_expiring") {
      const { data, count } = await supabase
        .from("v_iatf_training_matrix")
        .select("record_id, employee, skill, validity_status, days_to_expiry", { count: "exact" })
        .eq("plant_id", plantId)
        .in("validity_status", ["expired", "expiring_soon"])
        .order("days_to_expiry", { ascending: true })
        .limit(limit);
      return { total: count, items: data };
    }
    if (module === "iatf_stale") {
      const { data, count } = await supabase
        .from("v_iatf_audit_readiness")
        .select("doc_code, title, days_to_review", { count: "exact" })
        .eq("plant_id", plantId)
        .eq("doc_status", "stale")
        .limit(limit);
      return { total: count, items: data };
    }
    return { error: "Unknown module: " + module };
  }

  if (name === "read_kpis") {
    const { data } = await supabase.rpc("get_plant_snapshot", { p_plant_id: plantId });
    return data;
  }

  if (name === "navigate") {
    // Client-side tool; server just acknowledges. The hint is captured by the
    // main handler and returned alongside the text response.
    return { ok: true, hint: args };
  }

  return { error: "Unknown tool: " + name };
}

// =============================================================================
// Main handler
// =============================================================================
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // ─── Auth + manager-only gate ──────────────────────────────────────────
    const auth = req.headers.get("Authorization");
    if (!auth) throw new Error("401 Not authenticated");
    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: auth } },
    });
    const { data: { user }, error: authErr } = await userClient.auth.getUser();
    if (authErr || !user) throw new Error("401 Invalid token");

    const supabase = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: profile } = await supabase.from("users")
      .select("role, plant_id, full_name")
      .eq("id", user.id)
      .maybeSingle();
    if (!profile) throw new Error("403 User profile not found");
    if (!["plant_head", "admin"].includes((profile as any).role)) {
      throw new Error("403 Manager access only — your role is '" + (profile as any).role + "'");
    }
    const plantId = (profile as any).plant_id;

    // ─── Get user message + history ────────────────────────────────────────
    const body = await req.json() as { message: string; history?: any[] };
    if (!body.message) throw new Error("message required");
    // Cost knob: shorter history. 4 turns is plenty for voice context.
    const incoming = (body.history || []).slice(-4);
    const messages: any[] = [...incoming, { role: "user", content: body.message }];

    // ─── Cost knob: pre-check daily cap (fails fast, no API call burnt) ────
    {
      const { data: usage } = await supabase
        .from("voice_usage_daily")
        .select("message_count")
        .eq("plant_id", plantId)
        .eq("user_id", user.id)
        .eq("agent", AGENT)
        .eq("day", new Date().toISOString().slice(0, 10))
        .maybeSingle();
      const used = (usage as any)?.message_count ?? 0;
      const cap = (profile as any).ai_daily_cap_per_user ?? DAILY_CAP_DEFAULT;
      if (used >= cap) {
        return new Response(JSON.stringify({
          response_text: `You've hit today's voice limit of ${cap} messages. Plant_head can raise it in Plant settings.`,
          navigation: null,
          tools_called: [],
          state: { history: incoming },
        }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
      }
    }

    // ─── Conditional insights fetch — only on first turn or "analyze me" Q's
    // Insights ≈ 1.5k tokens. For "show me X" / "open Y", we don't need them.
    const wantsInsights =
      incoming.length === 0 ||
      /\b(summary|summarise|summarize|overview|biggest|top|critical|priorit|important|worry|risk|issue|problem|how are we|how is|what.s wrong|today|this week|month|kya|enna|important|risks?|bottleneck)\b/i.test(body.message);

    const [snapRes, insRes] = await Promise.all([
      supabase.rpc("get_plant_snapshot", { p_plant_id: plantId }),
      wantsInsights
        ? supabase.rpc("get_plant_insights", { p_plant_id: plantId })
        : Promise.resolve({ data: null }),
    ]);

    // Cost knob: compact JSON (no pretty-print → ~40% fewer chars)
    const snapshotBlock = `Plant: ${(profile as any).full_name || user.email}\n\nSNAPSHOT:\n${JSON.stringify(snapRes.data)}`;
    const insightsBlock = wantsInsights
      ? `INSIGHTS (correlations + patterns):\n${JSON.stringify(insRes.data)}\n\nUse INSIGHTS for synthesis. End with one named action.`
      : "Only SNAPSHOT this turn. Ask 'show me biggest risks' for full analytical insights.";

    // ─── Tool-use loop ─────────────────────────────────────────────────────
    const toolsCalled: string[] = [];
    let navigationHint: any = null;
    let finalText = "";

    // Cost knob: cap tool-use loop to 3 iterations (was 5) — most queries
    // finish in 1-2 turns; we were paying for occasional infinite-spiral edge cases.
    let totalIn = 0, totalOut = 0, totalCacheRead = 0, totalCacheCreate = 0;
    for (let iter = 0; iter < 3; iter++) {
      const apiRes = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-api-key": ANTHROPIC_KEY,
          "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify({
          model: MODEL,
          // Cost knob: 1024 → 500. Voice answers should be short anyway.
          max_tokens: 500,
          // Cost knob: multi-block caching so each chunk gets its own 5-min TTL.
          // STATIC prompt rarely changes → always cached. SNAPSHOT changes only
          // when DB changes → cached for rapid follow-ups in same minute.
          system: [
            { type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } },
            { type: "text", text: snapshotBlock, cache_control: { type: "ephemeral" } },
            { type: "text", text: insightsBlock },
          ],
          tools: TOOLS,
          messages,
        }),
      });
      if (!apiRes.ok) {
        const t = await apiRes.text();
        throw new Error(`Anthropic ${apiRes.status}: ${t.slice(0, 400)}`);
      }
      const data = await apiRes.json();
      const content = data.content || [];
      // Accumulate tokens for usage log
      const u = data.usage || {};
      totalIn += u.input_tokens || 0;
      totalOut += u.output_tokens || 0;
      totalCacheRead += u.cache_read_input_tokens || 0;
      totalCacheCreate += u.cache_creation_input_tokens || 0;

      // Capture text blocks
      const textBlocks = content.filter((c: any) => c.type === "text");
      if (textBlocks.length > 0) {
        finalText = textBlocks.map((t: any) => t.text).join("\n").trim();
      }

      // Capture tool_use blocks
      const toolUses = content.filter((c: any) => c.type === "tool_use");
      if (toolUses.length === 0) break;

      // Push assistant turn with full content (mixed text + tool_use)
      messages.push({ role: "assistant", content });

      // Execute every tool, build tool_result block list
      const toolResults: any[] = [];
      for (const tu of toolUses) {
        toolsCalled.push(tu.name);
        try {
          const result = await executeTool(supabase, plantId, tu.name, tu.input);
          if (tu.name === "navigate") navigationHint = tu.input;
          toolResults.push({
            type: "tool_result",
            tool_use_id: tu.id,
            content: JSON.stringify(result).slice(0, 4000),
          });
        } catch (err) {
          toolResults.push({
            type: "tool_result",
            tool_use_id: tu.id,
            is_error: true,
            content: "Tool error: " + (err as Error).message,
          });
        }
      }
      messages.push({ role: "user", content: toolResults });

      if (data.stop_reason === "end_turn") break;
    }

    // Build history for next turn (final assistant text only — drop tool turns)
    const updatedHistory = [
      ...incoming,
      { role: "user", content: body.message },
      { role: "assistant", content: finalText || "(no response)" },
    ];

    // Log usage (best-effort; don't block response if it fails)
    supabase.rpc("track_voice_usage", {
      p_plant_id: plantId,
      p_user_id: user.id,
      p_agent: AGENT,
      p_in: totalIn,
      p_out: totalOut,
      p_cache_read: totalCacheRead,
      p_cache_create: totalCacheCreate,
    }).then(() => {}).catch((e: Error) => console.warn("usage log failed:", e.message));

    return new Response(JSON.stringify({
      response_text: finalText || "I couldn't generate a reply, please try again.",
      navigation: navigationHint,
      tools_called: toolsCalled,
      manager_name: (profile as any).full_name,
      state: { history: updatedHistory },
      tokens: { input: totalIn, output: totalOut, cache_read: totalCacheRead, cache_create: totalCacheCreate },
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err) {
    const msg = (err as Error).message || "Internal error";
    const status = msg.startsWith("401") ? 401 : msg.startsWith("403") ? 403 : 500;
    return new Response(JSON.stringify({ error: msg }), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
