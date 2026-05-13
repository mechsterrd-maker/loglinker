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
const MODEL             = "claude-sonnet-4-20250514";

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

const SYSTEM_PROMPT = `You are "Logi", the voice-first AI assistant for managers (plant_head / admin) at this Loglinkr plant.

You are READ-ONLY. You can search, read, summarize, and navigate. You CANNOT and MUST NOT create, update, or delete anything. If asked to write something, politely tell the manager to use the normal entry forms.

LANGUAGE — match the manager's language exactly:
- Tamil → Tamil reply
- Hindi → Hindi reply
- English → English reply
- Tanglish / Hinglish → reply in the same mixed style
- Detect from each user message; switch if they switch.

THIS IS A VOICE INTERFACE — your text will be SPOKEN aloud:
- Use SHORT sentences. No markdown, no bullet points, no asterisks.
- Avoid long lists; say "I found three, the most critical is…".
- Numbers: spell small numbers in words ("two NCRs"), use digits for large.
- End with a brief prompt: "Tap to open it" / "Should I read more?" / "Anything else?".

TOOL USE RULES (mandatory):
1. ALWAYS call \`navigate\` after answering about a specific document, record, or module. Even if the user didn't ask, the UI relies on this to render a tap-to-open button.
2. For "summary" / "how is the plant" / "give me an overview" → call \`read_kpis\` first.
3. For "show me / how many ___" → call \`query_open_items\` with the right module.
4. For a specific doc code / NCR number / vendor name → call \`search_documents\` or \`read_iatf_doc\`.
5. Don't fabricate counts or status. If a tool returned 0, say so honestly.

You're the manager's hands-free QA partner walking the shop floor.`;

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
    const incoming = (body.history || []).slice(-10);
    const messages: any[] = [...incoming, { role: "user", content: body.message }];

    // ─── Tool-use loop ─────────────────────────────────────────────────────
    const toolsCalled: string[] = [];
    let navigationHint: any = null;
    let finalText = "";

    for (let iter = 0; iter < 5; iter++) {
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
          system: [
            { type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } },
            { type: "text", text: `Plant: ${(profile as any).plant_id} | Manager: ${(profile as any).full_name || user.email}` },
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

    return new Response(JSON.stringify({
      response_text: finalText || "I couldn't generate a reply, please try again.",
      navigation: navigationHint,
      tools_called: toolsCalled,
      manager_name: (profile as any).full_name,
      state: { history: updatedHistory },
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
