# Loglinkr — MD Briefing · Talking Points

Open with the **framing**, not with features. The MD is comparing apples to oranges; correct the comparison first.

---

## 1. Open with the right question

> "MD, I want to clear one thing first. The question isn't *Freedom ERP vs Loglinkr*. They solve different problems. Freedom is our books. Loglinkr is our brain. Cherry-picking 2 of 25 modules from Loglinkr is the most expensive way to use it."

If MD presses on "why two systems?":

> "Every auto-component SME you respect already runs two — one ERP for accounting, one shop-floor / quality system. We're just naming ours."

---

## 2. What Freedom does well — concede this early

Listing this builds trust. Don't attack Freedom.

- Books of accounts · trial balance · P&L · balance sheet
- GST returns · TDS · e-invoice · e-way bill
- Vendor ageing · customer outstanding · cash flow
- Payroll, PF, ESI, wage register
- Vendor master, raw stock ledger for GL purposes

**Verdict:** keep using Freedom for all of this. Don't try to do accounting in Loglinkr.

---

## 3. What Freedom can't do — where we lose money / audit points today

Bring this back to **what the MD already knows hurts**:

| Pain | Today (Freedom + WhatsApp + paper) | With Loglinkr |
|---|---|---|
| Operator logs a shot | 5 min at office PC, often days late | 30 sec, voice in Tamil on his phone |
| Vendor sends bill on WhatsApp | Someone re-types it next day | OCR extracts everything, GRN draft auto-created |
| Customer schedule vs supply | Monthly Excel reconciliation, gaps surface as complaints | Live; outward DC auto-supplies the schedule |
| NCR / breakdown raised | WhatsApp + phone calls + forgotten | Push to plant head + maint + quality in &lt;1 sec, auto-task created |
| **IATF audit prep** | 4–6 weeks of folder-hunting | Live dashboard with 33 docs, click-to-export |
| Reject root cause | "Rejected 60 nos" free-text — useless | Structured per-stage codes, live Pareto by part / die / machine |
| Oil / coolant / leak checks | Paper log book, ignored after week 2 | 30-sec TPM check, default-OK, critical → auto breakdown |
| NPD (RFQ → SOP) | Email threads + folder of PDFs | Phase gates, commercials, docs, decisions, auto-feeds PPAP |

If the MD interrupts on any row, dig into that one specifically.

---

## 4. Three things no traditional ERP does

Memorise these three — they're the differentiation.

1. **AI on the shop floor.** Operators speak Tamil / Hindi → AI fills form. OCR reads vendor invoices. Plant-aware AI assistant answers "why is rejection up this week?" with actual data.
2. **Cascades.** One event triggers everywhere. NCR → task → push → All Hands chat → daily summary → escalation if overdue. ERPs report. Loglinkr reacts.
3. **IATF 16949 native.** Every required IATF document mapped to a clause. PFMEA, PPAP, LPA, MR, Risk Register, CSR, NPD/APQP, Control Plan, Skills Matrix, Calibration — built in, not bolted on. Auditor finds evidence in 30 seconds.

---

## 5. Numbers to claim — defendable

Use round numbers, don't oversell.

- **60–90% reduction** in operator data-entry time (voice + photo + default-OK + part picker)
- **&lt; 2 seconds** from NCR raised to plant head's lock-screen popup
- **4 weeks → 2 days** IATF audit preparation cycle
- **Zero manual schedule reconciliation** when the bill carries the customer's name (alias map)
- **One app** replaces internal WhatsApp groups + paper log books + spreadsheet handoffs
- **33 IATF documents** tracked live with clause + owner + cadence

If MD asks "how do you know?" — say *"these are conservative from what's already shipping; pilot confirms exact numbers for our plant."*

---

## 6. The cherry-picking trap (counter the MD's current position)

He likes Production Entry + Task Manager. Don't fight that — embrace it, then show what's hidden inside them.

> "Production Entry isn't just a logbook. One shot logged consumes BOM → updates raw stock → updates die strokes → forecasts next die change → feeds Pareto + OEE + customer schedule supply. Turn off the cascades and we're paying for a typing machine."

> "Task Manager isn't a todo list. Tasks auto-spawn from NCR, breakdown, TPM critical fail, overdue stage log, customer complaint. Each task arrives with the linked record's context. Operator doesn't search — the task carries it."

**Punchline:** "Cherry-pick 2 modules, leave cascades off, and we pay 2× for 20% of the value."

---

## 7. The architecture — make him visualise it

Two systems, side-by-side, with handoffs at clear points.

```
                    Freedom ERP                        Loglinkr
                    -----------                        --------
  Books / GL          ✓ owns
  Tax / GST           ✓ owns
  Payroll             ✓ owns
  Vendor master       ✓ owns (master)                  ← reads
  AP / AR ledger      ✓ owns                           ← posts GRN, DC
                                                       (sync = 2 hooks)
  Shop floor entry                                     ✓ owns
  OEE / rejects                                        ✓ owns
  Customer schedule                                    ✓ owns
  NCR / PPAP / PFMEA                                   ✓ owns
  Maintenance / TPM                                    ✓ owns
  IATF dashboard                                       ✓ owns
  All Hands chat                                       ✓ owns
  NPD / APQP                                           ✓ owns
```

Sync points are two: GRN → Freedom AP, Sales DC/invoice → Freedom AR. Standard auto-component IT shape.

---

## 8. The ask — 30-day pilot

Frame as **no commitment, hard go/no-go**:

- One plant (suggest the smaller one — quicker to learn)
- All modules on, full cascades on
- No parallel paper, no parallel Excel
- Freedom continues unchanged for accounting
- After 30 days: measure data-entry time, NCR closure time, audit-readiness %, operator NPS
- If gain isn't seen → revert, no penalty, no contract trap

This is the strongest possible position: "MD, if I'm wrong, we lose 30 days. If I'm right, we save 30% of our quality team's time forever."

---

## 9. Close with the one-liner

When you sense MD is convinced or just running out of patience, lock it in:

> **"Freedom is our books. Loglinkr is our brain. Both keep us in business."**

Then stop talking. Let him decide.

---

## Likely objections + responses

**"Why can't Freedom add these features?"**
> They can in 18-24 months, like every other ERP did with WhatsApp integrations. By then we'll have lost 2 customer audits and 6% PPM. We need it now.

**"Can the ops team handle two systems?"**
> Operators only see Loglinkr — voice and photo. Accounts only sees Freedom. Two systems, but each person sees one. The two sync at GRN and DC.

**"What if Loglinkr goes down?"**
> It's on Supabase (Postgres + RLS) and Vercel — same infrastructure 70% of new SaaS runs on. Daily backups. We can also export every table to CSV in one click for our own backup.

**"What about the cost?"**
> Compare to: (a) the manhours we spend re-typing WhatsApp bills, (b) the audit prep 4 weeks every year, (c) the customer complaint penalties we eat because schedule visibility is monthly. ROI is in the first audit cycle.

**"Aren't we locked in?"**
> Open data — every record is in Postgres. Our property. We can pull it out any time. We're not locked into the vendor; we're locked into our own data.

---

## Tab order (if showing the actual app)

1. Open **Home** — show the Plant Pulse + Quick Entry strip + by-dept summary
2. Tap **Chat → All Hands** — show the activity firehose, real cascades from real events
3. Open any **NCR** — show photo + voice + email-ref + part dropdown all on one form
4. **Schedules → Bill Mapping** — show how OCR'd bills auto-match a customer
5. **More → IATF Doc Library** — show that every document has a clause + owner + cadence
6. **More → NPD** — show one project with phases + commercials + docs + decision thread

That's a 6-minute live demo if MD wants to see it.

---

## Final sanity check

If you only have 60 seconds with MD before he leaves the room:

> "Freedom is our books. Loglinkr is our brain. Freedom does accounts, taxes, payroll — keep it. Loglinkr does shop-floor entry, IATF audit readiness, customer schedule tracking, and instant team communication — things Freedom was never built for. Cherry-picking 2 modules wastes 80% of the value. Give me 30 days on one plant. If the gain isn't real, we revert. No penalty."

End of pitch.
