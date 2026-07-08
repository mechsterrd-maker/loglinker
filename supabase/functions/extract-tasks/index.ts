// extract-tasks: turn a pasted list OR a photo (e.g. a WhatsApp message
// screenshot) into a clean list of tasks. Claude reads the text/image, splits
// it into discrete tasks, matches owner names to the plant's people and project
// names to its projects, and parses "by Friday" → a date. Returns rows the
// frontend reviews before inserting into `actions`.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-4-6";
const MAX_OUT = 8000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

function sliceJson(text: string): string {
  const cleaned = text.replace(/^```json\s*/i, "").replace(/```\s*$/, "").trim();
  if (cleaned.startsWith("{")) return cleaned;
  const a = text.indexOf("{"), b = text.lastIndexOf("}");
  return a >= 0 && b > a ? text.slice(a, b + 1) : cleaned;
}

function buildPrompt(people: string[], projects: string[], today: string): string {
  return `You are turning a manager's rough task list into structured tasks for a factory task tracker. The input is either pasted text or a photo of a message (often a WhatsApp message, possibly in Tamil / Hindi / Tanglish). Split it into DISCRETE tasks — one per actionable item. Ignore greetings, chatter, headers and signatures.

Today is ${today}. Parse relative dates ("by Friday", "tomorrow", "EOD", "நாளைக்கு") into an absolute YYYY-MM-DD. If no date is stated, use null.

People in this plant (match an owner to the CLOSEST one; use the EXACT name from this list, else null):
${people.length ? people.map((p) => "- " + p).join("\n") : "(none provided)"}

Projects in this plant (match if a task clearly belongs to one; use the EXACT name, else null):
${projects.length ? projects.map((p) => "- " + p).join("\n") : "(none provided)"}

For EACH task return:
- title: a short imperative task line (clean it up; keep it in English where reasonable but keep proper nouns)
- owner_user_name: the matched person's exact name from the list, or null
- project_name: the matched project's exact name, or null
- due_date: YYYY-MM-DD or null
- priority: "high" | "medium" | "low" (infer; default medium; "urgent"/"asap"/"immediately" → high)
- raw_quote: the original snippet this task came from (short)

Return ONLY valid JSON:
{
  "tasks": [
    {"title": "...", "owner_user_name": null, "project_name": null, "due_date": null, "priority": "medium", "raw_quote": "..."}
  ],
  "notes": "anything ambiguous the user should check, or null"
}`;
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
    const text: string = typeof body.text === "string" ? body.text.trim() : "";
    const imageB64: string = typeof body.image_base64 === "string" ? body.image_base64 : "";
    const mime: string = typeof body.mime === "string" ? body.mime : "image/jpeg";
    const people: string[] = Array.isArray(body.people) ? body.people.filter(Boolean).map(String) : [];
    const projects: string[] = Array.isArray(body.projects) ? body.projects.filter(Boolean).map(String) : [];
    const today: string = typeof body.today === "string" && /^\d{4}-\d{2}-\d{2}$/.test(body.today) ? body.today : new Date().toISOString().slice(0, 10);

    if (!text && !imageB64) return json({ error: "Provide text or an image." }, 400);

    const content: unknown[] = [];
    if (imageB64) content.push({ type: "image", source: { type: "base64", media_type: mime, data: imageB64 } });
    if (text) content.push({ type: "text", text: "PASTED TASK LIST:\n" + text });
    else content.push({ type: "text", text: "The task list is in the image above." });
    content.push({ type: "text", text: buildPrompt(people, projects, today) });

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({ model: MODEL, max_tokens: MAX_OUT, messages: [{ role: "user", content }] }),
    });
    const msg = await res.json();
    if (msg.type === "error" || msg.error) throw new Error(msg.error?.message || "Claude API error");
    const outText = (msg.content || []).filter((b: { type: string }) => b.type === "text").map((b: { text: string }) => b.text).join("\n");
    let data: { tasks?: unknown[]; notes?: string };
    try { data = JSON.parse(sliceJson(outText)); }
    catch { return json({ error: "Could not parse tasks", raw: outText.slice(0, 1500) }, 500); }

    const tasks = (Array.isArray(data.tasks) ? data.tasks : []).map((raw) => {
      const t = raw as Record<string, unknown>;
      const pr = String(t.priority || "medium").toLowerCase();
      return {
        title: String(t.title || "").trim(),
        owner_user_name: t.owner_user_name ? String(t.owner_user_name).trim() : "",
        project_name: t.project_name ? String(t.project_name).trim() : "",
        due_date: t.due_date && /^\d{4}-\d{2}-\d{2}$/.test(String(t.due_date)) ? String(t.due_date) : "",
        priority: ["high", "medium", "low"].includes(pr) ? pr : "medium",
        raw_quote: t.raw_quote ? String(t.raw_quote).slice(0, 200) : "",
      };
    }).filter((t) => t.title);

    // Log usage
    try {
      const svc = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
      const cost = (msg.usage?.input_tokens || 0) * 3 / 1e6 + (msg.usage?.output_tokens || 0) * 15 / 1e6;
      const { data: me } = await db.from("users").select("plant_id").eq("id", user.id).maybeSingle();
      if (me?.plant_id) await svc.from("ai_usage").insert({
        plant_id: me.plant_id, kind: imageB64 ? "task_extract:image" : "task_extract:text", model: MODEL,
        input_tokens: msg.usage?.input_tokens || 0, output_tokens: msg.usage?.output_tokens || 0,
        cost_usd: Number(cost.toFixed(6)),
      });
    } catch (_) { /* never fail on logging */ }

    return json({ success: true, tasks, notes: data.notes || null });
  } catch (e) {
    return json({ error: (e as Error).message || "Internal error" }, 500);
  }
});
