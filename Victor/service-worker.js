const CACHE = 'victor-v1';
const ASSETS = [
  './',
  './index.html',
  './css/style.css',
  './js/storage.js',
  './js/notifications.js',
  './js/app.js',
  './js/pages/home.js',
  './js/pages/screentime.js',
  './js/pages/workouts.js',
  './js/pages/martialarts.js',
  './js/pages/bible.js',
  './js/pages/scheduler.js',
  './js/pages/water.js',
  './js/pages/sleep.js',
  './js/pages/heartrate.js',
  './js/pages/habits.js',
  './js/pages/focus.js',
  './js/pages/journal.js',
  './js/pages/settings.js',
  './manifest.json',
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    )
  );
});
self.addEventListener('fetch', (e) => {
  e.respondWith(
    caches.match(e.request).then((r) => r || fetch(e.request))
  );
});