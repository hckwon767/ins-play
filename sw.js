const CACHE_NAME = 'instation-v2';
const STATIC_ASSETS = [
  '/',
  '/index.html',
  '/radio.js',
  '/manifest.json',
  '/icon-192.png',
  '/icon-512.png',
  'https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=Noto+Sans+KR:wght@300;400;500;700&display=swap',
];

/* 설치: 핵심 파일 사전 캐시 */
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache =>
      cache.addAll(STATIC_ASSETS).catch(() => {})
    )
  );
  self.skipWaiting();
});

/* 활성화: 이전 버전 캐시 삭제 */
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))
      )
    )
  );
  self.clients.claim();
});

/* Fetch 전략
   - 스트리밍 오디오 (live01.inlive.co.kr 등 *.inlive.co.kr): 캐시 건너뜀
   - CORS 프록시 (api.allorigins.win): 캐시 건너뜀 (항상 최신 데이터 필요)
   - 채널 이미지 (cdn.inlive.co.kr): Cache-First
   - 앱 셸 (index.html, radio.js 등): Network-First → 실패 시 캐시 */
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);

  /* 오디오 스트림: 네트워크 직통 */
  if (url.hostname.endsWith('.inlive.co.kr') && url.hostname !== 'cdn.inlive.co.kr') return;

  /* CORS 프록시: 네트워크 직통 */
  if (url.hostname === 'api.allorigins.win') return;

  /* 채널 썸네일: Cache-First */
  if (url.hostname === 'cdn.inlive.co.kr') {
    event.respondWith(
      caches.match(event.request).then(cached => {
        if (cached) return cached;
        return fetch(event.request).then(res => {
          if (res && res.ok) {
            const clone = res.clone();
            caches.open(CACHE_NAME).then(c => c.put(event.request, clone));
          }
          return res;
        }).catch(() => cached);
      })
    );
    return;
  }

  /* 앱 셸: Network-First */
  event.respondWith(
    fetch(event.request)
      .then(res => {
        if (res && res.ok) {
          const clone = res.clone();
          caches.open(CACHE_NAME).then(c => c.put(event.request, clone));
        }
        return res;
      })
      .catch(() => caches.match(event.request))
  );
});
