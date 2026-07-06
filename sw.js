/* USCW Seminar Check-In — service worker
   Cache-first for the app shell so the kiosk runs fully offline once installed.
   Bump CACHE to ship an update; old caches are purged on activate. */
const CACHE = 'uscw-checkin-v1';

// Paths are relative to this script's location, so they resolve correctly under
// the GitHub Pages subpath (…/Seminar-Check-In-App/).
const PRECACHE = [
  './',
  './index.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
  './apple-touch-icon.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE)
      .then((cache) => cache.addAll(PRECACHE))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  // Non-GET (e.g. Global Relay / Calendly POSTs) is left to the network entirely.
  if (req.method !== 'GET') return;
  // Cache-first: serve precached shell assets offline; anything else falls through
  // to the network and is never cached (live API GETs must not be served stale).
  event.respondWith(
    caches.match(req, { ignoreSearch: true }).then((cached) => cached || fetch(req))
  );
});
