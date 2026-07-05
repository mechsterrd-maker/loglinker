// FLO — Loglinkr's in-app AI assistant ("JARVIS for the factory").
// Claude tool-use loop over the user's own RLS-scoped data:
//   query_data  → assistant_query RPC (read-only SQL, RLS as the signed-in user)
//   create_task → insert into actions (as the signed-in user)
//   navigate    → returned to the client, which switches tabs
// Usage is logged to ai_usage (kind 'assistant') via the service role.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-opus-4-8";
const MAX_ROUNDS = 8;
const VERSION = "flo-v2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const NAV_TABS = ["home", "production", "quality", "maintenance", "stocks", "actions", "documents", "schedules", "reports", "chat", "attendance", "petty_cash", "npd", "projects", "people"];

const TOOLS = [
  {
    name: "query_data",
    description: "Run a read-only SQL SELECT against the plant's Postgres database. Row-level security automatically scopes results to the user's plant and permitted units — do not filter by plant_id. Returns up to 200 rows as JSON. Single statement only; no writes. If you are unsure of a table's columns, first query information_schema.columns (e.g. select column_name from information_schema.columns where table_name='actions').",
    input_schema: {
      type: "object",
      properties: { sql: { type: "string", description: "A single SELECT (or WITH…SELECT) statement." } },
      required: ["sql"],
    },
  },
  {
    name: "create_task",
    description: "Create a task (action) assigned to a person. First resolve the owner's user id with query_data (select id, full_name from users where full_name ilike '%name%'). If several people match, ask the user which one instead of guessing. Due date is optional.",
    input_schema: {
      type: "object",
      properties: {
        title: { type: "string" },
        description: { type: "string" },
        owner_id: { type: "string", description: "UUID of the user the task is assigned to" },
        owner_name: { type: "string", description: "The owner's name, for confirmation in your reply" },
        due_date: { type: "string", description: "YYYY-MM-DD (optional)" },
        priority: { type: "string", enum: ["low", "normal", "high", "urgent"] },
      },
      required: ["title", "owner_id"],
    },
  },
  {
    name: "navigate",
    description: "Open a section of the Loglinkr app for the user. Use when they ask to open/show/go to a module. Call at most once per reply.",
    input_schema: {
      type: "object",
      properties: { tab: { type: "string", enum: NAV_TABS } },
      required: ["tab"],
    },
  },
];

function buildSystem(ctx: { name: string; role: string; plant: string; unit: string; units: string; today: string; voice: boolean }) {
  return `You are FLO, Loglinkr's built-in plant copilot — a sharp, friendly assistant living inside a factory-operations app used by Indian fabrication and die-casting plants. Think JARVIS for the shop floor: fast, factual, zero fluff.

## Who you're talking to
${ctx.name} (${ctx.role}) at ${ctx.plant}. Active unit: ${ctx.unit}. Units they can access: ${ctx.units}.
Today is ${ctx.today} (IST). The database stores timestamps in UTC — for "today"/date grouping use (ts at time zone 'Asia/Kolkata')::date. Date columns like log_date/check_date are already plain dates.

## Ground rules
- EVERY number you state must come from query_data in this conversation. Never estimate or invent data. If a query returns nothing, say so.
- RLS already scopes all queries to this user's plant and permitted units — never filter by plant_id; unit filtering happens automatically too.
- Currency is INR (₹, indian digit grouping). Format dates as "4 Jul 2026".
- Be concise. Lead with the answer, then a compact markdown table if listing rows (max ~10 rows shown; mention if more). Bold the key figure.
- If a query errors, check information_schema.columns for the real column names and retry (max 3 attempts), don't apologize at length.
- When the request is ambiguous (which unit? which part? which person?), ask one short clarifying question instead of guessing.
- You may create tasks and open app sections with your tools. Confirm what you did in one line ("✅ Task assigned to Naresh, due 6 Jul").
- Politely refuse things outside the plant/app (general web questions, code, other companies' data).
- LANGUAGE: mirror the user. Many users speak Tanglish — Tamil-English mix, often Tamil words in English letters ("innaiku production evlo?", "reject athigama irukka?") — understand it naturally and reply in the same mix. Pure Tamil → reply in Tamil (தமிழ்). Hindi/Hinglish → reply likewise. English → English. Keep technical terms (part codes, machine codes, numbers) as-is.${ctx.voice ? `

## VOICE CONVERSATION MODE (active now)
You are in a live spoken conversation — your reply will be read aloud by text-to-speech.
- Reply like a human colleague speaking: 1–3 short sentences, warm and natural.
- NO markdown, NO tables, NO bullet lists, NO emoji, NO symbols like | or #.
- Speak numbers naturally ("about twelve thousand five hundred" style is not needed — plain "12,500" is fine, but round long decimals).
- If the answer would need a big table, give the headline figure and offer: "want me to show the full list on screen?" (then use navigate or wait for them to ask in text).
- Keep the conversation flowing — it's okay to end with a short natural follow-up question when useful.` : ""}

## Schema cheat-sheet (key tables; verify columns via information_schema when unsure)
- users(id, full_name, role, department, designation, primary_unit_id, active_unit_id, status) · units(id, name) · shifts(id, name) · departments(name)
- actions = TASKS(id, title, description, owner_id→users, assigned_by→users, due_at, status: open|in_progress|completed|cancelled, priority, department, unit_id, source_type, created_at)
- Production: mcp_pdc_parts(id, name, part_number), mcp_pdc_machines(id, code, display_name, status, category), mcp_pdc_dies, mcp_pdc_shots(machine_id, die_id, part_id, shots_good, shots_rejected, pieces_good, pieces_rejected, cavities, recorded_at, operator_user_id), mcp_pdc_stage_log(log_date, shift_id, part_id, stage, qty_good, qty_rejected, status, is_provisional, machine_id), mcp_pdc_machine_idle_log
- Maintenance: mcp_maintenance_breakdowns(machine_id, description, status: open|attended|resolved|cancelled, reported_at, attended_at, resolved_at, downtime_minutes, reported_by), mcp_tpm_runs(machine_id, check_date, operator_id, has_issues, issue_count), mcp_tpm_results(run_id, item_label, status: ok|issue, critical, note), iatf_pm_tasks, iatf_pm_executions
- Quality: mcp_quality_rejections, mcp_quality_ncrs, mcp_qa_inspections, mcp_customer_complaints, mcp_quality_ppm_base
- Stocks: mcp_stocks_items, mcp_stocks_transactions · Logistics/bills: mcp_logistics_documents(doc_type, vendor_name_raw, doc_number, doc_date), mcp_logistics_vendors, mcp_logistics_payments, mcp_logistics_grn_receptions, mcp_logistics_grn_lines
- Schedules vs supply: mcp_sched_schedules, mcp_sched_lines, mcp_sched_supplies, mcp_sched_customers
- People: mcp_attendance(user_id, work_date, status), mcp_expenses, mcp_petty_cash_books, mcp_petty_cash_txns
- NPD: mcp_npd_projects, mcp_npd_documents · Chat: chat_groups, chat_messages · IATF: iatf_* (calibration, training, audits, fmea, risk register…)
- machines is a view over mcp_pdc_machines (same rows).

## App sections for navigate
${NAV_TABS.join(", ")} — "actions" is the Tasks module.`;
}

async function runTool(
  block: { name: string; input: Record<string, unknown> },
  db: ReturnType<typeof createClient>,
  me: { id: string; plant_id: string },
  navActions: Array<{ type: string; tab: string }>,
): Promise<{ content: string; is_error?: boolean }> {
  try {
    if (block.name === "query_data") {
      const sql = String(block.input.sql || "");
      const { data, error } = await db.rpc("assistant_query", { p_sql: sql });
      if (error) return { content: "SQL error: " + error.message, is_error: true };
      let out = JSON.stringify(data ?? []);
      if (out.length > 30000) out = out.slice(0, 30000) + "…(truncated — narrow the query)";
      return { content: out };
    }
    if (block.name === "create_task") {
      const title = String(block.input.title || "").trim();
      const ownerId = String(block.input.owner_id || "").trim();
      if (!title || !ownerId) return { content: "title and owner_id are required", is_error: true };
      const row: Record<string, unknown> = {
        plant_id: me.plant_id,
        title,
        description: block.input.description || null,
        owner_id: ownerId,
        assigned_by: me.id,
        status: "open",
        source_type: "manual",
        source_label: "FLO assistant",
        priority: block.input.priority || "normal",
      };
      if (block.input.due_date) row.due_at = new Date(String(block.input.due_date) + "T18:00:00+05:30").toISOString();
      const { data, error } = await db.from("actions").insert(row).select("id, title").single();
      if (error) return { content: "Could not create task: " + error.message, is_error: true };
      return { content: JSON.stringify({ created: true, id: data.id, title: data.title }) };
    }
    if (block.name === "navigate") {
      const tab = String(block.input.tab || "");
      if (!NAV_TABS.includes(tab)) return { content: "unknown tab", is_error: true };
      navActions.push({ type: "navigate", tab });
      return { content: "ok — the app will open " + tab };
    }
    return { content: "unknown tool", is_error: true };
  } catch (e) {
    return { content: "tool failed: " + (e as Error).message, is_error: true };
  }
}

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
    const history: Array<{ role: string; content: string }> = Array.isArray(body.messages) ? body.messages : [];
    if (!history.length) return json({ error: "messages required" }, 400);
    const voiceMode = body.voice === true;

    // Context (all via the user's own RLS)
    const { data: me } = await db.from("users")
      .select("id, full_name, role, plant_id, active_unit_id")
      .eq("id", user.id).maybeSingle();
    if (!me) return json({ error: "No profile" }, 403);
    const [{ data: plant }, { data: units }] = await Promise.all([
      db.from("plants").select("name").eq("id", me.plant_id).maybeSingle(),
      db.from("units").select("id, name").eq("plant_id", me.plant_id),
    ]);
    const unitName = (units || []).find((u: { id: string }) => u.id === me.active_unit_id)?.name || "—";
    const today = new Date().toLocaleDateString("en-IN", { timeZone: "Asia/Kolkata", day: "numeric", month: "short", year: "numeric", weekday: "long" });

    const system = buildSystem({
      name: me.full_name || user.email || "user",
      role: me.role || "member",
      plant: plant?.name || "plant",
      unit: unitName,
      units: (units || []).map((u: { name: string }) => u.name).join(", ") || "—",
      today,
      voice: voiceMode,
    });

    // Conversation: client sends plain-text turns; tool blocks live only server-side within this request.
    let msgs: Array<{ role: string; content: unknown }> = history.slice(-16)
      .filter((m) => m && (m.role === "user" || m.role === "assistant") && typeof m.content === "string" && m.content.trim())
      .map((m) => ({ role: m.role, content: m.content }));
    if (!msgs.length || msgs[0].role !== "user") return json({ error: "first message must be from the user" }, 400);

    const navActions: Array<{ type: string; tab: string }> = [];
    const usage = { input: 0, output: 0 };
    let finalText = "";

    for (let round = 0; round < MAX_ROUNDS; round++) {
      const res = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
        body: JSON.stringify({
          model: MODEL,
          max_tokens: 4096,
          system,
          messages: msgs,
          tools: TOOLS,
          thinking: { type: "adaptive" },
          output_config: { effort: "medium" },
        }),
      });
      const msg = await res.json();
      if (msg.type === "error" || msg.error) throw new Error(msg.error?.message || "Claude API error");
      usage.input += msg.usage?.input_tokens || 0;
      usage.output += msg.usage?.output_tokens || 0;

      if (msg.stop_reason === "tool_use") {
        msgs.push({ role: "assistant", content: msg.content });
        const results = [];
        for (const block of msg.content) {
          if (block.type !== "tool_use") continue;
          const r = await runTool(block, db, me, navActions);
          results.push({ type: "tool_result", tool_use_id: block.id, content: r.content, ...(r.is_error ? { is_error: true } : {}) });
        }
        msgs.push({ role: "user", content: results });
        continue;
      }

      finalText = (msg.content || []).filter((b: { type: string }) => b.type === "text").map((b: { text: string }) => b.text).join("\n").trim();
      break;
    }
    if (!finalText) finalText = "I ran out of steps on that one — try asking a narrower question.";

    // Usage log (service role; founder-only cost visibility reads this table)
    try {
      const svc = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
      const cost = usage.input * 5 / 1e6 + usage.output * 25 / 1e6;
      await svc.from("ai_usage").insert({
        plant_id: me.plant_id, kind: "assistant", model: MODEL,
        input_tokens: usage.input, output_tokens: usage.output,
        cost_usd: Number(cost.toFixed(6)),
      });
    } catch (_) { /* usage logging must never fail the reply */ }

    return json({ reply: finalText, actions: navActions, version: VERSION });
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});
