const CACHE_NAME = 'instation-v2';
const STATIC_ASSETS = [
  '/',
  '/index.html',
  '/channels.json',
  '/manifest.json',
  '/icon-192.png',
  '/icon-512.png',
  'https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=Noto+Sans+KR:wght@300;400;500;700&display=swap',
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => cache.addAll(STATIC_ASSETS).catch(()=>{}))
  );
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);

  // 오디오 스트림: 캐시 없이 네트워크 직통
  if (url.hostname.endsWith('.inlive.co.kr') && url.hostname !== 'cdn.inlive.co.kr') return;

  // 채널 썸네일: Cache-First
  if (url.hostname === 'cdn.inlive.co.kr') {
    event.respondWith(
      caches.match(event.request).then(cached => {
        if (cached) return cached;
        return fetch(event.request).then(res => {
          if (res?.ok) caches.open(CACHE_NAME).then(c => c.put(event.request, res.clone()));
          return res;
        }).catch(() => cached);
      })
    );
    return;
  }

  // channels.json + 앱 셸: Network-First (오프라인 fallback 있음)
  event.respondWith(
    fetch(event.request)
      .then(res => {
        if (res?.ok) caches.open(CACHE_NAME).then(c => c.put(event.request, res.clone()));
        return res;
      })
      .catch(() => caches.match(event.request))
  );
});
