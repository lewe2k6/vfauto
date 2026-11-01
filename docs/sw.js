const CACHE_NAME = 'vf-bss-qr-rescue-v2';
const CORE_ASSETS = [
  './',
  './index.html',
  './styles.css',
  './vision.js',
  './ocr_qr.js',
  './app.js',
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

self.addEventListener('fetch', function (event) {
  if (event.request.method !== 'GET') return;
  event.respondWith(
    caches.match(event.request).then(function (cached) {
      if (cached) return cached;
      return fetch(event.request).then(function (resp) {
        if (resp && resp.status === 200) {
          const clone = resp.clone();
          caches.open(CACHE_NAME).then(function (c) {
            c.put(event.request, clone).catch(function () {});
          });
        }
        return resp;
      }).catch(function () {
        return cached;
      });
    })
  );
});
