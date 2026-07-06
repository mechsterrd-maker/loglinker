// supabase/functions/extract-schedule/index.ts
// V4: multi-image support — a schedule photographed in several overlapping
// parts is merged into ONE dataset; duplicate (part × date) cells that appear
// in more than one photo are deduplicated (model-level rules + server-side
// safety net). Model bumped to claude-sonnet-4-6. Robust JSON slicing.
// NOTE: deployed via Supabase MCP deploy_edge_function — this file is the
// tracked mirror of what's live.

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import Anthropic from 'https://esm.sh/@anthropic-ai/sdk@0.31.0';

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY')!;
const client = new Anthropic({ apiKey: ANTHROPIC_API_KEY });
const MODEL = 'claude-sonnet-4-6';
const MAX_IMAGES = 6;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const SCHEDULE_PROMPT = `You are reading a customer purchase schedule for an Indian Tier 1/2 auto component supplier.

CRITICAL: Extract every (Part, Date, Quantity) combination as a SEPARATE LINE. Do NOT sum or bucket.

MULTI-IMAGE RULES (when more than one image is provided):
- All images are photos of the SAME schedule document, taken in parts because it did not fit in one photo (left/right halves, top/bottom, page 1/2…).
- The photos may OVERLAP: the same row, part, or date columns can appear in more than one image. Treat everything as ONE dataset.
- Each unique (part × delivery date) must appear ONLY ONCE in your output. If the same part+date cell is visible in two images with the same qty, output it once. If the two images disagree (one blurry/cut off), use the clearer/complete value and mention it in notes.
- A part's date columns may CONTINUE across images (image 1 has days 1-15, image 2 has days 16-31) — combine them into one row set.
- Read the customer name / month from whichever image shows the header.

Schedules come in 3 formats. Detect which and extract accordingly:

FORMAT A — Daily date columns (most common for Indian Tier 1):
   | ITEM        | 2 | 4 | 5 | 6 | 7 | 8 | ...
   | Old adaptor | 2000 | 2000 | 2000 | 2000 | 2000 | | ...

   Each non-empty cell = ONE line. Old adaptor cells on dates 2,4,5,6,7 → output 5 lines.

FORMAT B — Weekly buckets:
   | ITEM | W1 | W2 | W3 | W4 |
   Convert each week to its first day: W1→day 1, W2→day 8, W3→day 15, W4→day 22, W5→day 29.

FORMAT C — Specific date columns ("5-May", "12-May", etc.):
   One line per non-empty cell with that exact date.

RULES:
- Date columns may show day numbers only (1-31) — combine with schedule month to form full date.
- "Total" column/row is for verification only — DO NOT extract it as a line.
- Skip empty/zero/dash cells, header rows, total rows.
- Part name is the leftmost text column.
- Customer part code (if present) is usually next to part name (e.g. "576041").
- Auto-detect schedule month from header text.

Return ONLY valid JSON (no markdown, no commentary before or after):

{
  "customer_name": "string",
  "customer_short_code": "string or null",
  "schedule_month": "YYYY-MM-01",
  "customer_ref": "string or null",
  "format_detected": "daily|weekly|date_list",
  "lines": [
    {"part_name_raw": "...", "customer_part_number": null, "delivery_date": "YYYY-MM-DD", "planned_qty": 2000, "uom": "nos"}
  ],
  "extraction_summary": {"total_parts": 4, "total_lines": 38, "total_qty": 90000, "date_range": "..."},
  "notes": null,
  "confidence": "high|medium|low"
}

Before responding, mentally sum extracted qty per part. If "Total" column exists in doc, your sums should match — if not, recheck. With multiple images, double-check you have not emitted the same part+date twice.`;

function sliceJson(text: string): string {
  const cleaned = text.replace(/^```json\s*/i, '').replace(/```\s*$/, '').trim();
  if (cleaned.startsWith('{')) return cleaned;
  const a = text.indexOf('{');
  const b = text.lastIndexOf('}');
  return a >= 0 && b > a ? text.slice(a, b + 1) : cleaned;
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });
  try {
    const { image_url, image_base64, media_type, images } = await req.json();

    // Normalize to an array of image blocks (new multi-image API + legacy single-image)
    const list: Array<{ base64?: string; url?: string; media_type?: string }> = [];
    if (Array.isArray(images)) {
      for (const im of images.slice(0, MAX_IMAGES)) {
        if (im && (im.base64 || im.image_base64 || im.url)) {
          list.push({ base64: im.base64 || im.image_base64, url: im.url, media_type: im.media_type });
        }
      }
    }
    if (!list.length && (image_base64 || image_url)) {
      list.push({ base64: image_base64, url: image_url, media_type });
    }
    if (!list.length) {
      return new Response(JSON.stringify({ error: 'images[] or image_base64/image_url required' }), {
        status: 400, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' }
      });
    }

    const content: any[] = [];
    list.forEach((im, i) => {
      if (list.length > 1) content.push({ type: 'text', text: `IMAGE ${i + 1} of ${list.length}:` });
      content.push(im.base64
        ? { type: 'image', source: { type: 'base64', media_type: im.media_type || 'image/jpeg', data: im.base64 } }
        : { type: 'image', source: { type: 'url', url: im.url } });
    });
    content.push({ type: 'text', text: SCHEDULE_PROMPT });

    const response = await client.messages.create({
      model: MODEL,
      max_tokens: 12000,
      messages: [{ role: 'user', content }]
    });

    const text = response.content.filter((b: any) => b.type === 'text').map((b: any) => b.text).join('\n');
    let extracted: any;
    try { extracted = JSON.parse(sliceJson(text)); }
    catch {
      return new Response(JSON.stringify({ error: 'Failed to parse Claude response as JSON', raw_response: text.slice(0, 2000) }),
        { status: 500, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
    }

    // Server-side dedupe safety net: one line per (part, part-code, date).
    // Overlapping photos sometimes still produce the same cell twice.
    if (Array.isArray(extracted.lines)) {
      const seen = new Map<string, any>();
      let dropped = 0;
      for (const l of extracted.lines) {
        const key = [
          String(l.part_name_raw || '').trim().toLowerCase(),
          String(l.customer_part_number || '').trim().toLowerCase(),
          String(l.delivery_date || ''),
        ].join('|');
        if (seen.has(key)) { dropped++; continue; }
        seen.set(key, l);
      }
      if (dropped > 0) {
        extracted.lines = [...seen.values()];
        extracted.notes = ((extracted.notes ? extracted.notes + ' · ' : '') +
          dropped + ' duplicate line(s) from overlapping photos merged automatically');
        if (extracted.extraction_summary) {
          extracted.extraction_summary.total_lines = extracted.lines.length;
          extracted.extraction_summary.total_qty = extracted.lines.reduce((s: number, l: any) => s + (Number(l.planned_qty) || 0), 0);
        }
      }
    }

    return new Response(JSON.stringify({
      success: true, data: extracted,
      usage: { input_tokens: response.usage.input_tokens, output_tokens: response.usage.output_tokens }
    }), { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
  } catch (err: any) {
    console.error('extract-schedule error:', err);
    return new Response(JSON.stringify({ error: err.message || 'Internal error' }),
      { status: 500, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
  }
});
