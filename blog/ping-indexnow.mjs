#!/usr/bin/env node
/**
 * Ping IndexNow (Bing, Yandex, etc.) with newly published URLs so they get
 * crawled almost immediately. Google does not use IndexNow — Google indexing
 * is handled by the auto-updated sitemap.xml submitted in Search Console.
 *
 * Usage:
 *   node blog/ping-indexnow.mjs https://loglinkr.com/blog/<slug>
 *   node blog/ping-indexnow.mjs            (no args = pings the newest post in posts.json)
 *
 * Best-effort: never throws in a way that would block publishing.
 */
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const data = JSON.parse(readFileSync(join(here, 'posts.json'), 'utf8'));
const HOST = new URL(data.site || 'https://loglinkr.com').host;

// Find the IndexNow key file at repo root (<key>.txt whose content === filename stem).
let key = null;
try {
  for (const f of readdirSync(root)) {
    const m = /^([a-f0-9]{8,32})\.txt$/.exec(f);
    if (m && readFileSync(join(root, f), 'utf8').trim() === m[1]) { key = m[1]; break; }
  }
} catch (_) {}
if (!key) { console.error('IndexNow key file not found at repo root — skipping ping.'); process.exit(0); }

let urls = process.argv.slice(2);
if (urls.length === 0 && data.posts && data.posts[0]) {
  urls = [`https://${HOST}/blog/${data.posts[0].slug}`];
}
if (urls.length === 0) { console.error('No URLs to submit.'); process.exit(0); }

const body = {
  host: HOST,
  key,
  keyLocation: `https://${HOST}/${key}.txt`,
  urlList: urls,
};

try {
  const res = await fetch('https://api.indexnow.org/indexnow', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
    body: JSON.stringify(body),
  });
  console.log(`IndexNow: submitted ${urls.length} URL(s) — HTTP ${res.status}`);
} catch (e) {
  console.error('IndexNow ping failed (non-fatal):', e.message);
}
