# LogLinkr Blog — Weekly Automation Playbook

This file is the single source of truth for the automated weekly blog publisher.
The scheduled task clones the repo, reads THIS file, and follows it exactly.
Editing this file changes how future posts are written — no other change needed.

## What the automation does, each run

1. **Clone** the repo (branch `main`).
2. **Pick the next topic:** open `blog/topic-queue.json`. Take the FIRST object in
   `queue` whose `"status"` is `"todo"`. If none are `todo`, invent a fresh, relevant
   topic in the same spirit (attendance / payroll / overtime / compliance / a specific
   industry) and continue — never publish a duplicate of an existing post.
3. **Research (optional but preferred):** do 1–2 quick web searches on the keyword to
   pull in any current facts, then write from knowledge. Never fabricate statistics —
   if a number isn't verifiable, describe the range qualitatively.
4. **Write the post** as `blog/<slug>/index.html` following the TEMPLATE RULES below.
   The `<slug>` is lowercase, hyphenated, derived from the title (keep it short).
5. **Register it:** add an object to the top of the `posts` array in `blog/posts.json`
   with: slug, title, description (150–160 chars), category, keyword, date (today,
   ISO `YYYY-MM-DD`), author `"LogLinkr Team"`, and a short `cardTitle` (≤ 60 chars).
6. **Mark the topic done:** set that queue item's `"status"` to `"done"`.
7. **Rebuild:** run `node blog/build.mjs` (regenerates `blog/index.html`, `sitemap.xml`,
   `robots.txt`). Confirm it prints a success line with the new post count.
8. **Publish:** commit and push to `main`. Vercel auto-deploys within ~30 seconds.
9. **Notify search engines (IndexNow):** run
   `node blog/ping-indexnow.mjs https://loglinkr.com/blog/<slug>`
   to instantly tell Bing/Yandex about the new post. This is best-effort and must
   never block publishing. (Google is handled automatically by the sitemap — see below.)
10. **Report:** state which post was published and its live URL
    (`https://loglinkr.com/blog/<slug>`).

## How indexing works (already set up)

- **Google:** the site is verified in Google Search Console and `sitemap.xml` is submitted
  there once. Because `blog/build.mjs` rewrites `sitemap.xml` (with a fresh `lastmod`) on
  every run, Google re-crawls the sitemap and indexes new posts on its own — no per-post
  action needed. Do NOT use Google's Indexing API for these posts (it is only sanctioned for
  job/livestream pages and can cause problems).
- **Bing / Yandex:** handled instantly by the IndexNow ping in step 9.
- The root file `<key>.txt` is the IndexNow verification key — never delete or rename it.

## TEMPLATE RULES (match the existing post exactly)

Copy the structure of `blog/face-recognition-attendance-system-guide/index.html`. Every post MUST have:

- The **same `<head>`**: the analytics line `<script src="/ga.js"></script>` right after
  the viewport meta tag (required — this is the Google Analytics tag; every page must have
  it exactly once), fonts, `blog.css`, a unique `<title>` (≤ 60 chars, include the
  keyword), a unique meta description, canonical URL
  `https://loglinkr.com/blog/<slug>`, and Open Graph + Twitter tags.
- **Two JSON-LD blocks**: an `Article` block (with today's `datePublished`/`dateModified`)
  and a `FAQPage` block whose questions match the on-page FAQ.
- The **exact same `<nav>` and `<footer>`** markup as the sample post (copy verbatim).
- An `<header class="article-head">` with breadcrumb, `<h1>` (keyword near the front),
  and an `.article-meta` row (category tag, date, read time, author).
- Body inside `<main class="narrow"><article>…</article></main>`.

### Content quality bar
- **Length:** 1,300–2,000 words. Useful and specific, never padded.
- **Structure:** a short intro, a `.keytakeaway` box near the top, 5–8 `<h2>` sections,
  at least one comparison `<table>` OR a numbered how-to list, one `<blockquote>` insight,
  a `.faq` accordion (4–6 Q&As matching the FAQ schema), and a `.cta-band` at the end
  linking to `/app?app=hr` ("Start your free trial").
- **Voice:** plain English, warm, practical. Speak to Indian small/mid business owners
  AND a general global audience — avoid jargon; explain any term you use.
- **Product tie-in:** mention LogLinkr naturally where relevant (no hardware, phone-based
  face attendance, automatic payroll, WhatsApp payslips, ₹99/mo start, 45-day free trial),
  but lead with genuine help, not a sales pitch. ~80% helpful / 20% product.
- **Internal links:** link to `/blog` and at least one of `/?stay=1#pricing`,
  `/?stay=1#features`, or a related existing post in `blog/posts.json`.
- **Facts:** LogLinkr = face-recognition attendance + automatic payroll for SMBs.
  Plans: ₹99/mo (up to 50 employees, launch offer; regular ₹199), ₹399/mo (up to 200).
  Prices exclude 18% GST. 45-day free trial, no credit card. Runs on any Android device.

### Do NOT
- Do not change site files outside `blog/`, `sitemap.xml`, and `robots.txt`.
- Do not invent pricing, statistics, or customer names/quotes.
- Do not publish two posts targeting the same keyword.

## Git commands (auth is provided by the scheduled task at runtime)
```
git add -A
git commit -m "blog: publish <title>"
git push origin main
```
