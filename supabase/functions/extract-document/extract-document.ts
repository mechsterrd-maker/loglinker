// extract-document/index.ts  — v15 (plant-aware extraction)
// Loglinkr extraction worker. Reads a row from mcp_logistics_extraction_queue,
// fetches plant context (units + vendors + stock items), calls Claude vision with
// a strongly-typed prompt that returns:
//   • direction: 'in' | 'out' | 'interunit_in' | 'interunit_out' | 'jobwork_out' | 'jobwork_in'
//   • doc_type, vendor_match_id, is_returnable, confidence, flags[]
// Writes structured output to mcp_logistics_documents and the cascade triggers
// pick it up from there (auto-GRN for inward, auto-supplies for outward, etc).
//
// Backwards compatible: client may pass {queue_id} only.  Plant context is
// resolved from the queue row's plant_id using service role.
//
// Versioned so re-deploys are visible in get_logs / debug_payload.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { Image } from "https://deno.land/x/imagescript@1.2.17/mod.ts";

const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-4-20250514";
const WORKER_VERSION = "v19";

// Tunables
const VENDOR_CONTEXT_LIMIT = 60;   // top-N vendors fed to the model
const ITEM_CONTEXT_LIMIT   = 80;   // top-N stock items fed to the model

interface QueueRow {
  id: string;
  plant_id: string;
  message_id: string | null;
  group_id: string | null;
  image_url: string;
  attempts: number;
}

interface ExtractionPayload {
  is_document: boolean;
  classification: "document" | "non_document";
  direction?: "in" | "out" | "interunit_in" | "interunit_out" | "jobwork_out" | "jobwork_in" | "unknown";
  doc_type?: string;
  doc_number?: string | null;
  doc_date?: string | null;
  due_date?: string | null;
  vendor_name?: string | null;       // raw OCR string
  vendor_gstin?: string | null;
  vendor_match_id?: string | null;   // resolved against known vendors (uuid) or null
  buyer_name?: string | null;
  buyer_gstin?: string | null;
  from_unit_name?: string | null;    // for interunit
  to_unit_name?: string | null;      // for interunit
  is_returnable?: boolean;
  jobwork_process?: string | null;   // for jobwork_out: "plating", "heat treatment", etc.
  taxable_value?: number | null;
  tax_amount?: number | null;
  total_value?: number | null;
  items?: Array<Record<string, unknown>>;
  validation_note?: string;
  confidence?: "high" | "medium" | "low";
  flags?: string[];
}

const VALID_DOC_TYPES = new Set([
  "invoice_in", "invoice_out", "dc_in", "dc_out",
  "job_work_dc_out", "job_work_dc_in", "bill", "quote", "po",
  "other", "interunit_dc_out", "interunit_dc_in",
]);

// direction → doc_type when extractor returns direction but no doc_type
const DIRECTION_TO_DOC_TYPE: Record<string, string> = {
  "in":             "dc_in",          // refined below if invoice/bill/po seen
  "out":            "dc_out",
  "interunit_in":   "interunit_dc_in",
  "interunit_out":  "interunit_dc_out",
  "jobwork_out":    "job_work_dc_out",
  "jobwork_in":     "job_work_dc_in",
};

function buildPrompt(ctx: {
  plantName: string;
  plantLegalName: string | null;
  plantGstin: string | null;
  units: Array<{ id: string; name: string; address: string | null }>;
  vendors: Array<{ id: string; name: string; legal_name: string | null; gstin: string | null; is_jobwork_vendor: boolean }>;
  stockItems: Array<{ id: string; code: string; name: string }>;
}): string {
  const unitLines = ctx.units.length
    ? ctx.units.map((u, i) => `  ${i + 1}. ${u.name}${u.address ? ` — ${u.address}` : ""}`).join("\n")
    : "  (none configured)";

  const vendorLines = ctx.vendors.length
    ? ctx.vendors.map(v =>
        `  - id=${v.id} | name="${v.name}"${v.legal_name && v.legal_name !== v.name ? ` (legal: "${v.legal_name}")` : ""}${v.gstin ? ` | GSTIN ${v.gstin}` : ""}${v.is_jobwork_vendor ? " | JOB-WORK" : ""}`
      ).join("\n")
    : "  (none yet — first time vendor will be created on confirm)";

  const itemLines = ctx.stockItems.length
    ? ctx.stockItems.map(i => `  - ${i.code}: ${i.name}`).join("\n")
    : "  (none)";

  return `You are an extraction worker for Loglinkr — an audit-ready ERP for an Indian SME manufacturer. You will read ONE photo or scan of a logistics document (delivery challan / invoice / PO / bill / job-work DC) and return ONE strict JSON object.

═══════════════════════════════════════════════════════════
PLANT IDENTITY (this is "us" — figure out which side of the doc we are on)
═══════════════════════════════════════════════════════════
Name:        ${ctx.plantName}
Legal name:  ${ctx.plantLegalName ?? "(same)"}
GSTIN:       ${ctx.plantGstin ?? "(unknown)"}

UNITS we own (any of these as either party = "us", and party-to-party between two of these = INTERUNIT):
${unitLines}

═══════════════════════════════════════════════════════════
KNOWN VENDORS / CUSTOMERS (try to match the counterparty to one of these)
═══════════════════════════════════════════════════════════
${vendorLines}

═══════════════════════════════════════════════════════════
KNOWN STOCK ITEMS (use these spellings if a line item visibly matches one)
═══════════════════════════════════════════════════════════
${itemLines}

═══════════════════════════════════════════════════════════
DIRECTION RULES (most important)
═══════════════════════════════════════════════════════════
Determine which side of the document our plant is on:

• If the SELLER / CONSIGNOR / "From" is us (matches plant GSTIN, plant name, or one of our units) AND the BUYER / CONSIGNEE / "To" is one of our OTHER units →
    direction = "interunit_out"
    doc_type = "interunit_dc_out"
    Set from_unit_name and to_unit_name to the matching unit names.

• If the SELLER is one of our units AND the BUYER is us at a different unit →
    direction = "interunit_in"
    doc_type = "interunit_dc_in"

• If the SELLER is us AND the BUYER is a real external vendor/customer →
    direction = "out"
    doc_type = "invoice_out" if it's a tax invoice with rates/amounts
    doc_type = "dc_out" if it's a plain delivery challan (no rate/amount)

• If the BUYER is us AND the SELLER is an external vendor →
    direction = "in"
    doc_type = "invoice_in" or "dc_in" by the same rule
    BUT: if the document mentions "Job Work", "Sub-contract", "Process", "For Plating",
         "Heat Treatment", "Annealing", "Polishing", "Coating", "Grinding", "Machining",
         "Returnable", "Returnable basis", "Returnable for processing" → this is a return
         coming back from a job-work vendor (we sent material out, they processed it,
         now it's back). Set:
            direction = "jobwork_in"
            doc_type = "job_work_dc_in"
            jobwork_process = the named process

• If the SELLER is us AND the doc mentions any of the job-work / processing keywords above
  AND the BUYER is a vendor (not a final customer) →
    direction = "jobwork_out"
    doc_type = "job_work_dc_out"
    is_returnable = true
    jobwork_process = the named process

• If you can't tell with confidence → direction = "unknown", doc_type = "other".

═══════════════════════════════════════════════════════════
COUNTERPARTY MATCHING
═══════════════════════════════════════════════════════════
After picking direction, identify the counterparty (the OTHER side, not us):
  vendor_name      = exact OCR'd name as printed
  vendor_gstin     = OCR'd GSTIN of the counterparty
  vendor_match_id  = if the counterparty matches a row in KNOWN VENDORS by name OR
                     GSTIN (case-insensitive, fuzzy on name), return that row's id.
                     Else null. Do not guess. Match GSTIN > legal_name > name.

═══════════════════════════════════════════════════════════
IMAGE ORIENTATION & QUALITY
═══════════════════════════════════════════════════════════
If the image is rotated, tilted, or upside-down (text reads sideways relative
to the document's natural top), mentally rotate to upright before extracting.
The document is always upright in real life; the photo captured it at an angle.
Never use a rotated reading as an excuse to guess.

═══════════════════════════════════════════════════════════
ZERO-GUESS DISCIPLINE — the most important rule
═══════════════════════════════════════════════════════════
NEVER fabricate a value to fill a field. If a field is illegible, missing,
or you can't read it with confidence, the value is NULL. Period.
  ✗ Do not concatenate adjacent text into a doc_number
  ✗ Do not interpret a quantity as a monetary value
  ✗ Do not guess a vendor name from a partial reading
  ✗ Do not infer a date from context if no date is printed
  ✗ Do not fill items[] with column headers, footers, signature labels, or guesses
A confident NULL is far more valuable than a confident guess.

═══════════════════════════════════════════════════════════
DOC NUMBER — strict label-driven extraction
═══════════════════════════════════════════════════════════
doc_number is the value next to a clearly-LABELED header field:
  ✓ "DC No.", "DC Number", "Challan No.", "Invoice No.", "Bill No."
  ✓ "Doc #", "Document No.", "Reference No.", "Quote No.", "PO No."
NEVER take doc_number from:
  ✗ "SL no", "S.No", "Sr. No.", "Sl. No." — those are item-row indices
  ✗ Item descriptions, HSN codes, item names
  ✗ Adjacent unlabeled text
  ✗ Concatenations of multiple fields
If no clearly labeled doc-number field exists or the value is illegible, set
doc_number = null and add "doc_number_unreadable" to flags[].

═══════════════════════════════════════════════════════════
VENDOR NAME — printed business name only
═══════════════════════════════════════════════════════════
vendor_name MUST be the printed business name on the seller's letterhead /
header banner / topmost prominent line of the document.
NEVER use:
  ✗ Names from "Authorised Signatory" or signature blocks
  ✗ Names from "Customer Signature" zones
  ✗ Witness names, contact-person names, salesperson names
  ✗ Email-address local-parts (the part before @) as a name
If the printed business name is illegible or absent, set vendor_name = null AND
add "vendor_name_illegible" to flags[].

═══════════════════════════════════════════════════════════
LINE ITEMS — STRICT
═══════════════════════════════════════════════════════════
items[] must contain ONLY real product/material data ROWS from the line-item
table. The header row (column titles) is never a line item.

DO NOT include any of these as items:
  ✗ Column headers themselves: "Description of Goods", "Item Description",
    "Particulars", "Material", "Description", "Qty", "Rate", "Amount"
  ✗ "Total", "Sub-total", "Grand Total", "Amount in Words"
  ✗ "Received the above goods in good condition" / signature blocks
  ✗ Tax summary rows (CGST, SGST, IGST, Round-off, GST)
  ✗ Footer disclaimers, terms & conditions, bank details
  ✗ Empty rows, "—", or ditto-mark continuations

If the line-item table contains only headers and no data rows, items = [] (empty).

For each real DATA line, populate:
  name      — item description as printed (the data row, not the header above)
  hsn       — HSN/SAC code if visible, else null
  qty       — number, never null on a real line
  uom       — unit of measure (NOS, KGS, MT, PCS, SET…), null if absent
  rate      — unit rate, null on a pure DC with no prices
  amount    — qty × rate, null on a pure DC
  process   — for jobwork rows: which operation (plating, heat-treat…); else ""

═══════════════════════════════════════════════════════════
QUANTITY ≠ MONETARY VALUE — never confuse these
═══════════════════════════════════════════════════════════
A "Quantity" / "Qty" / "Pcs" / "Nos" column holds COUNTS, not money.
A "Rate" / "Unit Price" column holds per-unit money.
A "Amount" / "Value" / "Total" column holds line-totals (qty × rate).
A "Invoice Value" or "Grand Total" or "Net Total" column holds doc-level money.

NEVER:
  ✗ Treat 270 NOS as ₹270 or ₹27,000
  ✗ Multiply quantity by 10/100/1000 to "estimate" an amount
  ✗ Copy a quantity into total_value or taxable_value
  ✗ Read a missing rate as zero and produce amount = 0

═══════════════════════════════════════════════════════════
DC vs INVOICE — when there are no prices
═══════════════════════════════════════════════════════════
If the document is a pure Delivery Challan / DC / Material Issue Slip with
NO rate column, NO amount column, NO tax row, NO grand total in rupees:
   total_value = null
   taxable_value = null
   tax_amount = null
   each item.rate = null, item.amount = null
A DC moves goods without invoicing money — that is the whole purpose of having
DC and Invoice as separate documents. Never invent monetary values for a DC.

═══════════════════════════════════════════════════════════
ARITHMETIC SELF-CHECK (when there ARE prices)
═══════════════════════════════════════════════════════════
After listing items, verify:
  sum(items[].amount) ≈ taxable_value   (tolerate ±1 for round-off)
  total_value ≈ taxable_value + tax_amount
If either check fails, add "arithmetic_mismatch" to flags[] and explain in
validation_note. If the mismatch is large, prefer NULLING the less certain
field over publishing inconsistent numbers.

═══════════════════════════════════════════════════════════
DATES
═══════════════════════════════════════════════════════════
Always return ISO YYYY-MM-DD. Indian docs often use DD/MM/YY or DD-MMM-YY:
  "8-May-26"  → 2026-05-08
  "10-May-26" → 2026-05-10
  "05/05/24"  → 2024-05-05  (DD/MM/YY assumed unless context proves otherwise)
If the year is two digits and ambiguous, default to the current decade.
If the date is illegible / unreadable → set doc_date = null AND add
"date_unreadable" to flags[]. NEVER guess a date from surrounding context.

═══════════════════════════════════════════════════════════
CONFIDENCE
═══════════════════════════════════════════════════════════
confidence = "high"   sharp image, every field visible & legible, arithmetic balances
confidence = "medium" minor ambiguity (one field unclear, arithmetic off by <2%)
confidence = "low"    blurry / rotated / faded / handwritten / multiple fields missing

When confidence = "low", be MORE willing to null fields rather than guess.
A low-confidence extraction with 5 nulls is more useful than a low-confidence
extraction with 5 fabrications — humans can fill nulls; they can't easily
detect fabrications buried in plausible-looking output.

═══════════════════════════════════════════════════════════
OUTPUT FORMAT — RETURN ONLY THIS JSON, NO PROSE, NO MARKDOWN FENCES
═══════════════════════════════════════════════════════════
{
  "is_document": boolean,
  "classification": "document" | "non_document",
  "direction": "in" | "out" | "interunit_in" | "interunit_out" | "jobwork_out" | "jobwork_in" | "unknown",
  "doc_type": "<one of: invoice_in, invoice_out, dc_in, dc_out, job_work_dc_out, job_work_dc_in, interunit_dc_out, interunit_dc_in, bill, quote, po, other>",
  "doc_number": string | null,
  "doc_date": "YYYY-MM-DD" | null,
  "due_date": "YYYY-MM-DD" | null,
  "vendor_name": string | null,
  "vendor_gstin": string | null,
  "vendor_match_id": string | null,
  "buyer_name": string | null,
  "buyer_gstin": string | null,
  "from_unit_name": string | null,
  "to_unit_name": string | null,
  "is_returnable": boolean,
  "jobwork_process": string | null,
  "taxable_value": number | null,
  "tax_amount": number | null,
  "total_value": number | null,
  "items": [
    {"name": "...", "hsn": null, "qty": 0, "uom": null, "rate": null, "amount": null, "process": ""}
  ],
  "validation_note": "what you cross-checked, any concerns",
  "confidence": "high" | "medium" | "low",
  "flags": ["arithmetic_mismatch", "date_inferred", "low_quality_image", "vendor_unrecognized", "junk_filtered"]
}

If the image is not a logistics document at all (selfie, screenshot, random photo):
  is_document = false, classification = "non_document", leave other fields null/[].`;
}

// =============================================================================
// IMAGE PRE-PROCESSING — auto-rotate before extraction
// =============================================================================
// Phone photos of paper docs are often rotated 90°/180°/270°. The vision model
// can read rotated text but mangles it more often (digits, similar letters,
// proper nouns). One cheap "what rotation?" pre-call + a server-side rotate
// dramatically improves extraction quality on real-world inputs.

const ROTATION_PROMPT = `A document was photographed and the photo may be rotated. To make the document text read upright (left-to-right, top-to-bottom), how many degrees CLOCKWISE should the photo be rotated?

Answer with EXACTLY one number from this list:
0   — already upright, no rotation needed
90  — rotate 90 degrees clockwise (current text reads bottom-to-top)
180 — rotate 180 degrees (current text is upside down)
270 — rotate 270 degrees clockwise (current text reads top-to-bottom)

Output: a single number. No words, no explanation, no punctuation.`;

async function detectRotationDeg(imgB64: string, mediaType: string): Promise<number> {
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 16,
        messages: [{
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: mediaType, data: imgB64 } },
            { type: "text", text: ROTATION_PROMPT },
          ],
        }],
      }),
    });
    if (!res.ok) return 0;
    const data = await res.json();
    const text = (data.content
      ?.filter((b: { type: string }) => b.type === "text")
      ?.map((b: { text: string }) => b.text)
      ?.join("") ?? "").trim();
    const m = text.match(/\b(0|90|180|270)\b/);
    const deg = m ? parseInt(m[1], 10) : 0;
    return [0, 90, 180, 270].includes(deg) ? deg : 0;
  } catch (_e) {
    return 0; // Never let rotation detection break extraction
  }
}

async function rotateImageBytes(
  bytes: Uint8Array,
  deg: number,
): Promise<{ bytes: Uint8Array; mediaType: string } | null> {
  if (deg === 0) return null;
  try {
    const img = await Image.decode(bytes);
    // ImageScript's rotate() takes degrees clockwise. Our detectRotationDeg
    // returns "how many degrees CW to apply to make upright" — pass through.
    img.rotate(deg);
    // High JPEG quality (95) — small text on logistics docs (doc number, date,
    // GSTIN) needs every bit of fidelity; quality 85 was nulling those fields.
    const out = await img.encodeJPEG(95);
    return { bytes: out, mediaType: "image/jpeg" };
  } catch (_e) {
    return null; // Rotation failure → fall back to original bytes
  }
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 32768;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

// =============================================================================
// HI-RES FALLBACK
// =============================================================================
// Chat upload writes both:  <id>.<ext>  (compressed, used by default)
//                           <id>.orig.<ext>  (full-resolution original)
// When the first extraction comes back low-confidence (faded thermal print,
// tiny doc-numbers, etc.) we re-fetch the .orig sibling and retry. Cheap
// fallback that recovers ~80% of bad-photo failures without paying hi-res
// cost on every doc.

function deriveHiresUrl(url: string): string {
  // Insert ".orig" before the final extension.
  const m = url.match(/^(.+)(\.[a-zA-Z0-9]+)(\?.*)?$/);
  if (!m) return url + ".orig";
  return m[1] + ".orig" + m[2] + (m[3] ?? "");
}

function shouldEscalateToHires(parsed: ExtractionPayload): boolean {
  if (parsed.confidence === "low") return true;
  const flags = parsed.flags ?? [];
  const recoverableFlags = new Set([
    "doc_number_unreadable",
    "date_unreadable",
    "vendor_name_illegible",
    "low_quality_image",
  ]);
  if (flags.some(f => recoverableFlags.has(f))) return true;
  // Many critical fields nulled → likely worth a retry
  if (parsed.is_document) {
    let nullCount = 0;
    if (!parsed.doc_number) nullCount++;
    if (!parsed.doc_date) nullCount++;
    if (!parsed.vendor_name) nullCount++;
    if (!parsed.items || parsed.items.length === 0) nullCount++;
    if (nullCount >= 3) return true;
  }
  return false;
}

function safeJsonParse(raw: string): unknown {
  let cleaned = raw.trim();
  const fenceMatch = cleaned.match(/^```(?:json)?\s*\n?([\s\S]*?)\n?```$/);
  if (fenceMatch) cleaned = fenceMatch[1].trim();
  const firstBrace = cleaned.indexOf("{");
  const firstBracket = cleaned.indexOf("[");
  const start = firstBrace === -1 ? firstBracket
              : firstBracket === -1 ? firstBrace
              : Math.min(firstBrace, firstBracket);
  if (start > 0) cleaned = cleaned.slice(start);
  const lastBrace = cleaned.lastIndexOf("}");
  const lastBracket = cleaned.lastIndexOf("]");
  const end = Math.max(lastBrace, lastBracket);
  if (end > 0 && end < cleaned.length - 1) cleaned = cleaned.slice(0, end + 1);
  return JSON.parse(cleaned);
}

// Resolve doc_type from the model's direction + doc_type, with fallbacks.
function resolveDocType(parsed: ExtractionPayload): string {
  // 1. If model returned a valid doc_type, trust it.
  if (parsed.doc_type && VALID_DOC_TYPES.has(parsed.doc_type)) {
    return parsed.doc_type;
  }
  // 2. Else derive from direction.
  if (parsed.direction && DIRECTION_TO_DOC_TYPE[parsed.direction]) {
    let dt = DIRECTION_TO_DOC_TYPE[parsed.direction];
    // refine "in"/"out" → invoice if rates/amount were extracted
    if ((dt === "dc_in" || dt === "dc_out") && (parsed.tax_amount || parsed.taxable_value)) {
      dt = dt === "dc_in" ? "invoice_in" : "invoice_out";
    }
    return dt;
  }
  return "other";
}

async function fetchPlantContext(
  supabase: ReturnType<typeof createClient>,
  plantId: string,
) {
  // plant
  const { data: plant } = await supabase
    .from("plants")
    .select("id, name, legal_name, gstin")
    .eq("id", plantId)
    .maybeSingle();

  // units
  const { data: units } = await supabase
    .from("units")
    .select("id, name, address")
    .eq("plant_id", plantId)
    .order("name");

  // vendors — prefer recently used (we'd need a usage signal; fall back to created_at)
  const { data: vendors } = await supabase
    .from("mcp_logistics_vendors")
    .select("id, name, legal_name, gstin, is_jobwork_vendor")
    .eq("plant_id", plantId)
    .order("updated_at", { ascending: false })
    .limit(VENDOR_CONTEXT_LIMIT);

  // stock items — use most-recent for context
  const { data: items } = await supabase
    .from("mcp_stocks_items")
    .select("id, code, name")
    .eq("plant_id", plantId)
    .order("updated_at", { ascending: false })
    .limit(ITEM_CONTEXT_LIMIT);

  return {
    plantName:      plant?.name ?? "(unknown)",
    plantLegalName: plant?.legal_name ?? null,
    plantGstin:     plant?.gstin ?? null,
    units:          units ?? [],
    vendors:        vendors ?? [],
    stockItems:     items ?? [],
  };
}

interface AttemptResult {
  parsed: ExtractionPayload;
  rawResponse: string;
  rotationLog: number[];
  totalRotationDeg: number;
  imageUrl: string;
  bytesLen: number;
}

// One end-to-end pass: fetch the image, auto-rotate, call vision, parse JSON.
// Throws on any pipeline failure (caller catches and decides whether to retry).
async function attemptExtraction(
  url: string,
  prompt: string,
): Promise<AttemptResult> {
  const imgRes = await fetch(url);
  if (!imgRes.ok) throw new Error(`Image fetch ${imgRes.status} on ${url}`);
  const imgBuf = await imgRes.arrayBuffer();
  let bytes = new Uint8Array(imgBuf);
  let imgB64 = bytesToBase64(bytes);
  let mediaType = imgRes.headers.get("content-type") || "image/jpeg";
  if (mediaType.includes(";")) mediaType = mediaType.split(";")[0].trim();
  if (!["image/jpeg", "image/png", "image/webp", "image/gif"].includes(mediaType)) {
    mediaType = "image/jpeg";
  }

  // Single-pass auto-rotate.
  const rotationLog: number[] = [];
  {
    const deg = await detectRotationDeg(imgB64, mediaType);
    if (deg !== 0) {
      const rotated = await rotateImageBytes(bytes, deg);
      if (rotated) {
        bytes = rotated.bytes;
        mediaType = rotated.mediaType;
        imgB64 = bytesToBase64(bytes);
        rotationLog.push(deg);
      }
    }
  }
  const totalRotationDeg = rotationLog.reduce((s, d) => s + d, 0) % 360;

  const visionRes = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 3072,
      messages: [{
        role: "user",
        content: [
          { type: "image", source: { type: "base64", media_type: mediaType, data: imgB64 } },
          { type: "text", text: prompt },
        ],
      }],
    }),
  });

  if (!visionRes.ok) {
    throw new Error(`Vision API ${visionRes.status}: ${(await visionRes.text()).slice(0, 500)}`);
  }

  const visionData = await visionRes.json();
  const rawResponse = visionData.content
    ?.filter((b: { type: string }) => b.type === "text")
    ?.map((b: { text: string }) => b.text)
    ?.join("\n") ?? "";

  const parsed = safeJsonParse(rawResponse) as ExtractionPayload;
  if (typeof parsed.is_document !== "boolean") {
    throw new Error("Missing is_document boolean in extraction");
  }

  return {
    parsed,
    rawResponse,
    rotationLog,
    totalRotationDeg,
    imageUrl: url,
    bytesLen: bytes.length,
  };
}

// Probe whether the hi-res sibling exists (HEAD request, fast).
async function hiresAvailable(hiresUrl: string): Promise<boolean> {
  try {
    const r = await fetch(hiresUrl, { method: "HEAD" });
    return r.ok;
  } catch {
    return false;
  }
}

async function processQueueRow(
  supabase: ReturnType<typeof createClient>,
  row: QueueRow,
  forceHires = false,
) {
  const startedAt = Date.now();
  const newAttempts = row.attempts + 1;

  await supabase
    .from("mcp_logistics_extraction_queue")
    .update({
      status: "processing",
      attempts: newAttempts,
      last_attempted_at: new Date().toISOString(),
    })
    .eq("id", row.id);

  let stage = "init";
  let lastRawResponse: string | null = null;

  try {
    stage = "fetch_context";
    const ctx = await fetchPlantContext(supabase, row.plant_id);
    const prompt = buildPrompt(ctx);

    // ─── First pass: compressed image ───────────────────────────────────────
    stage = "extract_compressed";
    let attempt = await attemptExtraction(row.image_url, prompt);
    lastRawResponse = attempt.rawResponse;
    let escalated = false;

    if (attempt.parsed.is_document) {
      // ─── Hi-res escalation ────────────────────────────────────────────────
      // If the compressed pass struggled (low confidence / unreadable flags /
      // many nulls), fetch the .orig sibling and try again. Only one extra
      // call per low-confidence doc; happy-path docs pay nothing extra.
      const hiresUrl = deriveHiresUrl(row.image_url);
      const wantsRetry = forceHires || shouldEscalateToHires(attempt.parsed);
      if (wantsRetry && hiresUrl !== row.image_url && await hiresAvailable(hiresUrl)) {
        stage = "extract_hires";
        try {
          const hiresAttempt = await attemptExtraction(hiresUrl, prompt);
          if (hiresAttempt.parsed.is_document) {
            // Hi-res result wins as long as it actually classified the doc.
            attempt = hiresAttempt;
            lastRawResponse = hiresAttempt.rawResponse;
            escalated = true;
          }
        } catch (hErr) {
          console.warn(`hires retry failed: ${(hErr as Error).message}`);
          // Keep the compressed result — better than nothing.
        }
      }
    }

    const parsed = attempt.parsed;
    const rotationLog = attempt.rotationLog;
    const totalRotationDeg = attempt.totalRotationDeg;

    if (!parsed.is_document) {
      await supabase
        .from("mcp_logistics_extraction_queue")
        .update({
          status: "skipped",
          classification: "non_document",
          processed_at: new Date().toISOString(),
          extraction_ms: Date.now() - startedAt,
          error_message: null,
          raw_response: null,
          debug_payload: { worker_version: WORKER_VERSION, escalated_to_hires: escalated },
        })
        .eq("id", row.id);
      return { ok: true, queue_id: row.id, skipped: true };
    }

    const docType = resolveDocType(parsed);

    // Resolve vendor_id: trust the model's vendor_match_id only if it's a real uuid in our list.
    let resolvedVendorId: string | null = null;
    if (parsed.vendor_match_id && /^[0-9a-f-]{36}$/i.test(parsed.vendor_match_id)) {
      const { data: v } = await supabase
        .from("mcp_logistics_vendors")
        .select("id")
        .eq("id", parsed.vendor_match_id)
        .eq("plant_id", row.plant_id)
        .maybeSingle();
      if (v) resolvedVendorId = v.id;
    }

    // Build raw_extraction blob (everything the model returned + our metadata)
    const rawExtraction = {
      ...parsed,
      _worker_version: WORKER_VERSION,
      _model: MODEL,
      _resolved_doc_type: docType,
      _resolved_vendor_id: resolvedVendorId,
    };

    stage = "persist";
    const { data: doc, error: docErr } = await supabase
      .from("mcp_logistics_documents")
      .insert({
        plant_id: row.plant_id,
        doc_type: docType,
        doc_number: parsed.doc_number ?? null,
        doc_date: parsed.doc_date ?? null,
        due_date: parsed.due_date ?? null,
        vendor_id: resolvedVendorId,
        vendor_name_raw: parsed.vendor_name ?? null,
        vendor_gstin_raw: parsed.vendor_gstin ?? null,
        taxable_value: parsed.taxable_value ?? null,
        tax_amount: parsed.tax_amount ?? null,
        total_value: parsed.total_value ?? null,
        items: parsed.items ?? [],
        raw_extraction: rawExtraction,
        validation_note: parsed.validation_note ?? null,
        source_message_id: row.message_id,
        source_image_url: row.image_url,
        extracted_by_ai: true,
        extraction_status: "completed",
        status: "pending",
      })
      .select("id")
      .single();
    if (docErr) throw docErr;

    // Keep raw_response on disk only for medium/low confidence — saves bytes on the
    // happy path, preserves debugging info when something looks off.
    const keepRawForDebug = parsed.confidence !== "high"
                         || (parsed.flags && parsed.flags.length > 0);

    await supabase
      .from("mcp_logistics_extraction_queue")
      .update({
        status: "completed",
        result_doc_id: doc.id,
        classification: "document",
        processed_at: new Date().toISOString(),
        extraction_ms: Date.now() - startedAt,
        error_message: null,
        raw_response: keepRawForDebug ? lastRawResponse?.slice(0, 8192) ?? null : null,
        debug_payload: {
          worker_version: WORKER_VERSION,
          model: MODEL,
          confidence: parsed.confidence ?? null,
          flags: parsed.flags ?? [],
          direction: parsed.direction ?? null,
          resolved_doc_type: docType,
          vendor_match_id: resolvedVendorId,
          auto_rotated_deg: totalRotationDeg,
          auto_rotated_iterations: rotationLog.length,
          auto_rotated_log: rotationLog,
          escalated_to_hires: escalated,
          image_source: escalated ? "hires" : "compressed",
          image_url_used: attempt.imageUrl,
        },
      })
      .eq("id", row.id);

    return {
      ok: true,
      queue_id: row.id,
      doc_id: doc.id,
      doc_type: docType,
      direction: parsed.direction,
      confidence: parsed.confidence,
      flags: parsed.flags,
      auto_rotated_deg: totalRotationDeg,
      auto_rotated_log: rotationLog,
      escalated_to_hires: escalated,
    };

  } catch (err) {
    const e = err as Error;

    await supabase
      .from("mcp_logistics_extraction_queue")
      .update({
        status: "failed",
        raw_response: lastRawResponse?.slice(0, 8192) ?? null,
        error_message: `${stage}: ${e.message}`.slice(0, 500),
        debug_payload: {
          stage,
          exception_type: e.name,
          exception_message: e.message,
          stack: e.stack?.slice(0, 2000),
          model_used: MODEL,
          attempt_number: newAttempts,
          worker_version: WORKER_VERSION,
        },
        processed_at: new Date().toISOString(),
        extraction_ms: Date.now() - startedAt,
      })
      .eq("id", row.id);

    return { ok: false, queue_id: row.id, error: `${stage}: ${e.message}` };
  }
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

  const supabase = createClient(SUPABASE_URL, SERVICE_KEY);

  try {
    let body: {
      queue_id?: string;
      batch_size?: number;
      reextract_doc_id?: string;
      force_hires?: boolean;  // skip the "should I escalate?" check, always retry on .orig
    } = {};
    try { body = await req.json(); } catch { /* empty body ok */ }

    const forceHires = body.force_hires === true;

    let rows: QueueRow[];

    // Re-extract path: client passes an existing doc_id; we synthesise a queue row
    // pointing at the doc's source_image_url and process it again.
    if (body.reextract_doc_id) {
      const { data: srcDoc, error: srcErr } = await supabase
        .from("mcp_logistics_documents")
        .select("id, plant_id, source_message_id, source_image_url")
        .eq("id", body.reextract_doc_id)
        .maybeSingle();
      if (srcErr) throw srcErr;
      if (!srcDoc) throw new Error("reextract_doc_id not found");
      if (!srcDoc.source_image_url) throw new Error("source doc has no source_image_url");

      // Re-extracts get a fresh queue row decoupled from the original message — the
      // unique constraint on message_id only allows one queue row per chat message,
      // and we want to preserve the original extraction's audit trail untouched.
      // The new doc still carries source_image_url so the trace back is preserved.
      const { data: q, error: qErr } = await supabase
        .from("mcp_logistics_extraction_queue")
        .insert({
          plant_id: srcDoc.plant_id,
          message_id: null,
          group_id: null,
          image_url: srcDoc.source_image_url,
          status: "pending",
        })
        .select("id, plant_id, message_id, group_id, image_url, attempts")
        .single();
      if (qErr) throw qErr;
      rows = [q as QueueRow];
    } else if (body.queue_id) {
      const { data, error } = await supabase
        .from("mcp_logistics_extraction_queue")
        .select("id, plant_id, message_id, group_id, image_url, attempts")
        .eq("id", body.queue_id)
        .limit(1);
      if (error) throw error;
      rows = (data ?? []) as QueueRow[];
    } else {
      const limit = Math.min(body.batch_size ?? 5, 10);
      const { data, error } = await supabase
        .from("mcp_logistics_extraction_queue")
        .select("id, plant_id, message_id, group_id, image_url, attempts")
        .eq("status", "pending")
        .order("created_at", { ascending: true })
        .limit(limit);
      if (error) throw error;
      rows = (data ?? []) as QueueRow[];
    }

    const results = [];
    for (const row of rows) {
      results.push(await processQueueRow(supabase, row, forceHires));
    }

    const success = results.length > 0 && results.every(r => r.ok);
    return new Response(
      JSON.stringify({ success, processed: results.length, results, worker_version: WORKER_VERSION }, null, 2),
      { headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } },
    );

  } catch (err) {
    const e = err as Error;
    return new Response(
      JSON.stringify({ success: false, error: e.message, stack: e.stack?.slice(0, 500) }),
      { status: 500, headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } },
    );
  }
});
