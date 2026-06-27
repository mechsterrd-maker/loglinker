// suggest-role-access — AI proposes a permission matrix for a custom role.
// Given a role name + description and the plant's module list, Claude returns
// a suggested {module_key: actions[]} matrix. SUGGESTION ONLY — the client
// pre-fills the grid and a human reviews/edits before saving. No DB writes.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-haiku-4-5";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface Module { key: string; label: string; group?: string }

function buildPrompt(roleName: string, roleDesc: string, modules: Module[], actions: string[]) {
  const moduleLines = modules.map(m => `- ${m.key} — ${m.label}${m.group ? ` (${m.group})` : ""}`).join("\n");
  return `You configure role-based access for "Loglinkr", an ERP for Indian SME manufacturing plants (many IATF 16949 certified).

Decide which modules this role should access, and at what action level, based ONLY on the role's name and description. Think like a plant manager assigning least-privilege access: grant what the role clearly needs to do its job, nothing more.

ROLE
- Name: ${roleName}
- Description: ${roleDesc || "(none provided — infer from the name)"}

AVAILABLE MODULES (use these exact keys only):
${moduleLines}

AVAILABLE ACTIONS (use these exact strings only): ${actions.join(", ")}

GUIDELINES
- Least privilege: a quality role gets quality/inspection/complaint modules; a purchase role gets documents/stocks/expenses; a supervisor gets shop-floor logging; etc.
- "view" is the baseline. Add create/edit only where the role actively does that work. Reserve "delete", "approve", "export" for senior/lead roles (managers, GMs, heads).
- Always include "home" with "view" so they have a landing page.
- Modules the role has no business in should be OMITTED entirely (not listed).
- Be decisive but conservative. A typical line role touches 3-8 modules; a senior role more.

Respond with STRICT JSON only, no prose, no markdown fences:
{"permissions":[{"module_key":"<key>","actions":["view",...]}],"notes":"<one or two short sentences explaining the access level you chose>"}`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...CORS } });

  try {
    if (req.method !== "POST") return json({ error: "POST only" }, 405);
    const { role_name, role_description, modules, actions } = await req.json();
    if (!role_name || !Array.isArray(modules) || modules.length === 0 || !Array.isArray(actions)) {
      return json({ error: "role_name, modules[] and actions[] are required" }, 400);
    }

    const validKeys = new Set(modules.map((m: Module) => m.key));
    const validActions = new Set(actions);

    const apiRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 1024,
        messages: [{ role: "user", content: buildPrompt(String(role_name), String(role_description || ""), modules, actions) }],
      }),
    });
    if (!apiRes.ok) {
      const t = await apiRes.text();
      return json({ error: "AI request failed", detail: t.slice(0, 300) }, 502);
    }
    const data = await apiRes.json();
    const text = (data.content || []).filter((b: { type: string }) => b.type === "text").map((b: { text: string }) => b.text).join("").trim();

    // Pull the first JSON object out of the response, tolerant of stray text/fences.
    let parsed: { permissions?: Array<{ module_key: string; actions: string[] }>; notes?: string } = {};
    const m = text.match(/\{[\s\S]*\}/);
    try { parsed = m ? JSON.parse(m[0]) : JSON.parse(text); } catch { parsed = {}; }

    // Validate: keep only known module keys + known actions. Guarantee home/view.
    const clean: Array<{ module_key: string; actions: string[] }> = [];
    const seen = new Set<string>();
    for (const p of (parsed.permissions || [])) {
      if (!p || !validKeys.has(p.module_key) || seen.has(p.module_key)) continue;
      const acts = Array.from(new Set((p.actions || []).filter((a: string) => validActions.has(a))));
      if (acts.length === 0) continue;
      seen.add(p.module_key);
      clean.push({ module_key: p.module_key, actions: acts });
    }
    if (validKeys.has("home")) {
      const home = clean.find(p => p.module_key === "home");
      if (home) { if (!home.actions.includes("view")) home.actions.unshift("view"); }
      else clean.unshift({ module_key: "home", actions: ["view"] });
    }

    return json({ permissions: clean, notes: (parsed.notes || "").toString().slice(0, 400) });
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});
