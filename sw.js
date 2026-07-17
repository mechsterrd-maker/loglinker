// sw.js — Loglinkr Service Worker
// Handles: PWA install, offline shell, Web Push notifications, click routing

const CACHE_NAME = 'loglinkr-v14';
const SHARE_CACHE = 'loglinkr-share';
const APP_SHELL = ['/app'];

// Install: cache app shell
self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then(c => c.addAll(APP_SHELL)).catch(() => {}));
  self.skipWaiting();
});

// Activate: clean old caches
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))))
  );
  self.clients.claim();
});

// Web Share Target — Android "Share → Loglinkr" posts the shared image/PDF here
// (manifest share_target action = /app?sharetarget=1). We can't hand a file to a
// page via URL, so stash the blob in a cache and redirect the opened window to
// /app?shared_bill=1, which the app reads on load and drops into the bill upload.
self.addEventListener('fetch', (event) => {
  const req = event.request;
  const u = new URL(req.url);
  // Match the share POST by PATH, not the ?sharetarget=1 query — some Android
  // builds drop the action's query string on a multipart POST, which made the
  // handler miss and the app just open blank. The app has no other same-origin
  // POST navigations (all API calls go to supabase.co, excluded below).
  const isShareTarget = req.method === 'POST' && u.origin === self.location.origin &&
    (u.searchParams.get('sharetarget') === '1' || u.pathname === '/app' || u.pathname === '/app.html' || u.pathname === '/app/');
  if (isShareTarget) {
    event.respondWith((async () => {
      try {
        const form = await req.formData();
        const file = form.get('bill') || form.get('image') || form.get('file') || (form.getAll ? form.getAll('bill')[0] : null);
        if (file && file.size) {
          const cache = await caches.open(SHARE_CACHE);
          await cache.put('/__shared-bill', new Response(file, {
            headers: { 'Content-Type': file.type || 'application/octet-stream', 'X-Shared-Name': (file.name || 'shared').replace(/[^\w.\-]/g, '_') },
          }));
        }
      } catch (_) { /* fall through to redirect regardless */ }
      // Response.redirect() requires an ABSOLUTE url — a relative path throws a
      // TypeError, which would drop us back to a plain app load (no bill).
      return Response.redirect(self.location.origin + '/app?shared_bill=1', 303);
    })());
    return;
  }
  if (req.method !== 'GET') return;
  // Skip API/Supabase/Edge function calls — always live
  const url = new URL(event.request.url);
  if (url.hostname.includes('supabase.co') || url.hostname.includes('anthropic.com')) return;
  event.respondWith(
    fetch(event.request)
      .then(res => {
        // Cache same-origin GET responses
        if (res.ok && url.origin === self.location.origin) {
          const clone = res.clone();
          caches.open(CACHE_NAME).then(c => c.put(event.request, clone)).catch(() => {});
        }
        return res;
      })
      .catch(() => caches.match(event.request).then(r => r || caches.match('/app')))
  );
});

// Push: show notification. Default deep-link is /app (root is now the marketing landing page).
self.addEventListener('push', (event) => {
  let data = { title: 'Loglinkr', body: 'You have a new notification', data: { url: '/app' } };
  try {
    if (event.data) data = event.data.json();
  } catch (e) {
    try { data.body = event.data?.text() || data.body; } catch (_) {}
  }
  const options = {
    body: data.body || '',
    icon: data.icon || '/icon-192.png',
    badge: data.badge || '/icon-96.png',
    data: data.data || {},
    tag: data.tag,
    renotify: true,
    requireInteraction: false,
    vibrate: [120, 60, 120],
  };
  event.waitUntil(self.registration.showNotification(data.title, options));
});

// Click: focus or open the app
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  // Normalise legacy '/' push payloads to /app, and bare deep-link slugs (/chat, /tasks, …) to
  // /app/<slug>, so a notification never strands the user on the marketing landing page.
  let url = event.notification.data?.url || '/app';
  if (url === '/' || url === '') url = '/app';
  else if (/^\/(chat|tasks|actions|schedules|documents|quality|maintenance|production)(\b|\/|\?)/.test(url)) url = '/app' + url;
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
      for (const c of list) {
        if ('focus' in c) {
          c.focus();
          if ('navigate' in c) c.navigate(url);
          return;
        }
      }
      if (clients.openWindow) return clients.openWindow(url);
    })
  );
});
