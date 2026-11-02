const CACHE_NAME = 'vf-bss-qr-rescue-v7';
const CORE_ASSETS = [
  './',
  './index.html',
  './map.html',
  './styles.css?v=4',
  './vision.js?v=4',
  './ocr_qr.js?v=4',
  './app.js?v=4',
  './manifest.json',
  './vendor/qrcode.js',
  './vendor/jsQR.js',
  './vendor/tesseract.min.js',
  './vendor/worker.min.js'
];

self.addEventListener('install', function (event) {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME).then(function (cache) {
      return Promise.allSettled(
        CORE_ASSETS.map(function (asset) {
          return cache.add(asset);
        })
      );
    })
  );
});

self.addEventListener('activate', function (event) {
  event.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(
        keys.map(function (k) {
          return k !== CACHE_NAME ? caches.delete(k) : Promise.resolve();
        })
      );
    }).then(function () {
      return self.clients.claim();
    })
  );
});

// Network-first for same-origin HTML/CSS/App JS, Cache-first for heavy vendor libraries; bypass cross-origin streams (e.g. ntfy.sh)
self.addEventListener('fetch', function (event) {
  if (event.request.method !== 'GET') return;
  let parsedUrl;
  try {
    parsedUrl = new URL(event.request.url);
  } catch (_) {
    return;
  }
  if (parsedUrl.origin !== self.location.origin) return;
  const url = event.request.url || '';
  const isVendor = url.indexOf('/vendor/') >= 0;

  if (isVendor) {
    event.respondWith(
      caches.match(event.request).then(function (cached) {
        if (cached) return cached;
        return fetch(event.request).then(function (resp) {
          if (resp && resp.status === 200) {
            const clone = resp.clone();
            caches.open(CACHE_NAME).then(function (c) { c.put(event.request, clone).catch(function () {}); });
          }
          return resp;
        });
      })
    );
    return;
  }

  event.respondWith(
    fetch(event.request).then(function (resp) {
      if (resp && resp.status === 200) {
        const clone = resp.clone();
        caches.open(CACHE_NAME).then(function (c) { c.put(event.request, clone).catch(function () {}); });
      }
      return resp;
    }).catch(function () {
      return caches.match(event.request);
    })
  );
});
