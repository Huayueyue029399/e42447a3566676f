/**
 * 台灣活動總覽 — Service Worker
 * 離線快取，提升載入速度與 PWA 支援
 */
const CACHE = 'tw-events-v1';
const URLS = ['index.html', 'events.js?v=2', 'manifest.json'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(URLS)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))));
});

self.addEventListener('fetch', e => {
  e.respondWith(
    caches.match(e.request).then(r => r || fetch(e.request).catch(() => new Response('離線模式', { status: 503 })))
  );
});
