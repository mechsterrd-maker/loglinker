#!/usr/bin/env node
/**
 * LogLinkr blog builder.
 * Reads blog/posts.json and regenerates:
 *   - blog/index.html   (the blog listing page)
 *   - sitemap.xml       (root, for SEO)
 *   - robots.txt        (root, points crawlers to the sitemap)
 *
 * Run from the repo root:  node blog/build.mjs
 * No dependencies. Safe to run any number of times.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const data = JSON.parse(readFileSync(join(here, 'posts.json'), 'utf8'));
const SITE = (data.site || 'https://loglinkr.com').replace(/\/$/, '');
const posts = [...(data.posts || [])].sort((a, b) => (a.date < b.date ? 1 : -1));

const LOGO = `<svg class="mark" viewBox="0 0 40 40" fill="none"><rect width="40" height="40" rx="10" fill="#2563eb"/><path d="M16 13a5 5 0 0 0 0 10h3M24 27a5 5 0 0 0 0-10h-3" stroke="#fff" stroke-width="2.6" stroke-linecap="round"/><path d="M16 20h8" stroke="#fff" stroke-width="2.6" stroke-linecap="round"/></svg>`;

const NAV = `<nav><div class="wrap">
  <a class="logo" href="/?stay=1">${LOGO}<div>LogLinkr<small>Workforce Simplified</small></div></a>
  <div class="navlinks">
    <a href="/?stay=1#features">Features</a>
    <a href="/?stay=1#how">How it works</a>
    <a href="/?stay=1#pricing">Pricing</a>
    <a href="/blog">Blog</a>
  </div>
  <div class="nav-cta"><a class="btn btn-p" href="/app?app=hr">Start Free</a></div>
</div></nav>`;

const FOOTER = `<footer><div class="wrap foot">
  <a class="logo" href="/?stay=1" style="font-size:19px">${LOGO} LogLinkr</a>
  <div>🌐 www.loglinkr.com</div>
  <div>© 2026 LogLinkr · Workforce Management Simplified</div>
</div></footer>`;

const fmtDate = (iso) => new Date(iso + 'T00:00:00Z').toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/* ---------- blog/index.html ---------- */
const cards = posts.map((p) => `
    <a class="card" href="/blog/${p.slug}">
      <div class="thumb">${esc(p.cardTitle || p.title)}</div>
      <div class="body">
        <span class="tag">${esc(p.category || 'Blog')}</span>
        <h3>${esc(p.title)}</h3>
        <p>${esc(p.description)}</p>
        <div class="meta">${fmtDate(p.date)} · ${esc(p.author || 'LogLinkr Team')}</div>
      </div>
    </a>`).join('\n');

const indexHtml = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Blog — LogLinkr | Attendance, Payroll & Workforce Tips</title>
<meta name="description" content="Practical guides on face-recognition attendance, payroll automation, overtime, compliance and running a smarter workforce — from the team at LogLinkr.">
<link rel="canonical" href="${SITE}/blog">
<meta name="theme-color" content="#2563eb">
<meta property="og:title" content="LogLinkr Blog — Attendance & Payroll made simple">
<meta property="og:description" content="Guides on face attendance, payroll automation, overtime and compliance for small and mid-sized businesses.">
<meta property="og:type" content="website">
<meta property="og:url" content="${SITE}/blog">
<meta property="og:site_name" content="LogLinkr">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/blog/blog.css">
</head>
<body>
${NAV}
<header class="blog-hero"><div class="wrap">
  <span class="eyebrow">LogLinkr Blog</span>
  <h1>Attendance & payroll, made simple.</h1>
  <p>Practical, no-jargon guides on face-recognition attendance, automatic payroll, overtime and compliance — for factories, shops, clinics and offices.</p>
</div></header>
<main class="wrap">
  <div class="grid">${cards}
  </div>
</main>
${FOOTER}
</body>
</html>
`;
writeFileSync(join(here, 'index.html'), indexHtml);

/* ---------- sitemap.xml ---------- */
const staticPages = ['/', '/install', '/loglinkr-overview', '/whats-new', '/blog'];
const urls = [
  ...staticPages.map((u) => ({ loc: SITE + u, lastmod: posts[0] ? posts[0].date : '2026-07-29' })),
  ...posts.map((p) => ({ loc: `${SITE}/blog/${p.slug}`, lastmod: p.date })),
];
const sitemap = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls.map((u) => `  <url><loc>${u.loc}</loc><lastmod>${u.lastmod}</lastmod></url>`).join('\n')}
</urlset>
`;
writeFileSync(join(root, 'sitemap.xml'), sitemap);

/* ---------- robots.txt ---------- */
writeFileSync(join(root, 'robots.txt'), `User-agent: *\nAllow: /\n\nSitemap: ${SITE}/sitemap.xml\n`);

console.log(`Built blog index with ${posts.length} post(s), sitemap.xml (${urls.length} URLs) and robots.txt.`);
