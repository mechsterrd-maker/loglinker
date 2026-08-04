// suggest-supply-matches — v1
// Stateless AI helper for the bill -> schedule "Map items" panel. Given a bill's
// line items and the customer's OPEN schedule parts, Claude proposes the best
// schedule part for each bill item with a confidence + one-line reason. It writes
// NOTHING — the user reviews and confirms each match in the app, which is what
// actually records the supply. Keeps supply data human-approved.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-4-6";
const WORKER_VERSION = "v1";

interface BillItem { name?: string | null; customer_part_number?: string | null; qty?: number | null; }
interface Candidate { line_id: string; part_name?: string | null; customer_part_number?: string | null; remaining?: number | null; }

const SYSTEM_PROMPT = `You match line items on a supplier's outward bill to the parts on their customer's delivery SCHEDULE, for an Indian manufacturing plant. You are given BILL ITEMS (what was dispatched) and SCHEDULE PARTS (the open demand, each with a stable line_id). For EACH bill item, choose the ONE schedule part it refers to, or null if none fits.

RULES — in strict priority order:
1. PART NUMBER is king. If a bill item's part number (in its own field OR printed inside its name, e.g. "METAL INSERT PART NO.9253805905" -> 9253805905, "MANIFOLD_4098" -> 4098) equals a schedule part's part number, that is the match — confidence "high". A number that matches the TAIL of the schedule part number counts (e.g. bill "53" -> schedule "54S30053").
2. If no part number resolves it, use the descriptive name. Abbreviations and vendor prefixes are expected: "RPL_INSERT_BIG" = "Big Insert" (RPL = the vendor), "ADAPTOR M002" ~ an adaptor part. Only match when the meaning clearly lines up. confidence "medium" for a solid name match, "low" if plausible but uncertain.
3. NEVER match two different bill items to the same schedule part unless they genuinely are the same part.
4. NEVER invent a line_id — use only ids from SCHEDULE PARTS. If nothing fits, line_id = null, confidence "none".
5. Do NOT touch or invent quantities. You only pick the part.

Return ONLY this JSON, no prose:
{"matches":[{"item_index":0,"line_id":"<uuid or null>","confidence":"high|medium|low|none","reason":"<=12 words"}]}
One entry per bill item, in the same order given.`;

function buildUserMsg(items: BillItem[], candidates: Candidate[]): string {
  const itemLines = items.map((it, i) =>
    `  [${i}] name="${it.name ?? ""}" part_no="${it.customer_part_number ?? ""}" qty=${it.qty ?? "?"}`
  ).join("\n");
  const candLines = candidates.map(c =>
    `  line_id=${c.line_id} | part="${c.part_name ?? ""}" | part_no="${c.customer_part_number ?? ""}" | remaining=${c.remaining ?? "?"}`
  ).join("\n");
  return `BILL ITEMS:\n${itemLines}\n\nSCHEDULE PARTS (open demand for this customer):\n${candLines}\n\nReturn the JSON mapping.`;
}

function parseJson(raw: string): unknown {
  let s = raw.trim();
  const fence = s.match(/^```(?:json)?\s*\n?([\s\S]*?)\n?```$/);
  if (fence) s = fence[1].trim();
  const a = s.indexOf("{"); const b = s.lastIndexOf("}");
  if (a > 0) s = s.slice(a);
  if (b >= 0 && b < s.length - 1) s = s.slice(0, s.lastIndexOf("}") + 1);
  return JSON.parse(s);
}

Deno.serve(async (req: Request) => {
  const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const items: BillItem[] = Array.isArray(body.items) ? body.items : [];
    const candidates: Candidate[] = Array.isArray(body.candidates) ? body.candidates : [];
    if (items.length === 0) return new Response(JSON.stringify({ matches: [] }), { headers: { ...cors, "Content-Type": "application/json" } });
    if (candidates.length === 0) {
      return new Response(JSON.stringify({ matches: items.map((_, i) => ({ item_index: i, line_id: null, confidence: "none", reason: "no open schedule parts" })), worker_version: WORKER_VERSION }), { headers: { ...cors, "Content-Type": "application/json" } });
    }
    const validIds = new Set(candidates.map(c => c.line_id));

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({ model: MODEL, max_tokens: 1024, temperature: 0,
        system: SYSTEM_PROMPT,
        messages: [{ role: "user", content: buildUserMsg(items, candidates) }] }),
    });
    if (!res.ok) throw new Error(`AI ${res.status}: ${(await res.text()).slice(0, 300)}`);
    const data = await res.json();
    const text = data.content?.filter((b: { type: string }) => b.type === "text")?.map((b: { text: string }) => b.text)?.join("") ?? "";
    const parsed = parseJson(text) as { matches?: Array<{ item_index?: number; line_id?: string | null; confidence?: string; reason?: string }> };
    const raw = Array.isArray(parsed.matches) ? parsed.matches : [];

    // Normalize: one entry per item, drop any hallucinated line_id, and never let
    // two items claim the same schedule part.
    const used = new Set<string>();
    const matches = items.map((_, i) => {
      const m = raw.find(x => x.item_index === i) ?? raw[i] ?? {};
      let lineId = (m.line_id && validIds.has(m.line_id)) ? m.line_id : null;
      let conf = ["high", "medium", "low", "none"].includes(m.confidence ?? "") ? m.confidence : (lineId ? "low" : "none");
      if (lineId && used.has(lineId)) { lineId = null; conf = "none"; }
      if (lineId) used.add(lineId);
      return { item_index: i, line_id: lineId, confidence: lineId ? conf : "none", reason: (m.reason ?? "").slice(0, 120) };
    });

    return new Response(JSON.stringify({ matches, worker_version: WORKER_VERSION }), { headers: { ...cors, "Content-Type": "application/json" } });
  } catch (err) {
    const e = err as Error;
    return new Response(JSON.stringify({ error: e.message, worker_version: WORKER_VERSION }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
  }
});
