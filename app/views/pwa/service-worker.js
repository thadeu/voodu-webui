// Voodu — service worker
//
// Goal: make static assets (brand SVG/PNG, fonts, Propshaft-
// fingerprinted CSS/JS bundles) load from the local cache so
// repeat visits and route transitions feel instant. We do NOT
// cache HTML pages, JSON endpoints, /cable, /logs/*/stream, or
// anything under /api/ — Voodu's UI is data-heavy and stale
// operator data on disk is worse than a slow request to the
// controller.
//
// Strategy matrix:
//
//   /assets/<file>-<hash>.<ext>   cache-first (hashed = safe forever)
//   /icon.*  /mono-*.* /mark-*.*  cache-first (brand chrome, stable)
//   /fonts/voodu/*                cache-first (font files don't churn)
//   *.svg / *.png / *.woff2 / *.css / *.js (same-origin)
//                                 cache-first
//   text/event-stream             passthrough (no respondWith)
//   /api/* /cable /*/stream       passthrough — never cached
//   HTML navigations              passthrough — always fetch fresh
//   everything else (GET)         passthrough
//
// Cache versioning: bump `SW_VERSION` to invalidate. Activate
// step purges every `voodu-cache-*` key that isn't the current one.

const SW_VERSION = "v1";
const CACHE_NAME = `voodu-cache-${SW_VERSION}`;

// Brand static URLs we know exist at install time. These are the
// "always show the logo even offline" baseline. Bundles get
// cached on first encounter via runtime caching below.
const PRECACHE_URLS = [
  "/icon.png",
  "/icon.svg",
  "/mark-rose-dark.svg",
  "/mono-black.svg",
  "/mono-white.svg",
  "/mono-white-512.png",
  "/fonts/voodu/Geist-Variable.woff2",
  "/fonts/voodu/GeistMono-Variable.woff2",
];

// Endpoints with side-effects, live streams, or operator-specific
// data — these MUST always hit the network. Adding /pods, /metrics,
// /logs etc. would leak between operator sessions and serve stale
// values.
const NEVER_CACHE_RE = new RegExp(
  [
    "^/api/",
    "^/cable",
    "/stream($|\\?)",
    "/broadcasts($|\\?)",
    "/logs/[^/]+/stream",
    "^/state-sync",
    "^/exports/",
    "^/service-worker",
  ].join("|")
);

// File extensions safe to cache long-term. These cover the brand
// kit + Propshaft-emitted bundle outputs. CSS/JS bundles get a
// content hash in the filename so the URL changes when content
// changes — making cache-first safe.
const STATIC_EXT_RE = /\.(png|jpg|jpeg|gif|svg|webp|ico|woff|woff2|ttf|otf|css|js|map)$/i;

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE_NAME)
      .then((cache) => cache.addAll(PRECACHE_URLS))
      // `.catch` so a single 404 (e.g. mono-white-512.png renamed)
      // doesn't tank the whole install. Logged for debugging; the
      // SW still activates and runtime caching fills the gaps.
      .catch((err) => console.warn("[voodu-sw] precache failed:", err))
  );
  // Take over immediately on first install — no waiting for all
  // open tabs to close. Operator hits refresh once and gets the
  // newer SW.
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((k) => k.startsWith("voodu-cache-") && k !== CACHE_NAME)
          .map((k) => caches.delete(k))
      )
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const req = event.request;

  // Non-GET requests bypass the SW entirely (POST/PUT/DELETE/etc.
  // are inherently uncacheable and routing them through respondWith
  // adds latency for no benefit).
  if (req.method !== "GET") return;

  const url = new URL(req.url);

  // Same-origin only. Cross-origin requests (CDN, controller's
  // direct IP if ever called from the browser) keep the browser's
  // default behaviour — the SW isn't the right layer to police
  // those.
  if (url.origin !== self.location.origin) return;

  if (NEVER_CACHE_RE.test(url.pathname)) return;

  // SSE / EventSource — must stay live. Without this guard the SW
  // would buffer the stream waiting for a complete response and
  // the log tail / metrics tick channels would hang.
  const accept = req.headers.get("accept") || "";
  if (accept.includes("text/event-stream")) return;

  // Cacheable: Propshaft bundles, brand assets, fonts.
  const isStatic =
    url.pathname.startsWith("/assets/") ||
    url.pathname.startsWith("/fonts/") ||
    STATIC_EXT_RE.test(url.pathname);

  if (isStatic) {
    event.respondWith(cacheFirst(req));
    return;
  }

  // Everything else — navigation HTML, JSON endpoints — pass
  // through to the network. No respondWith() = browser default
  // (which includes its own HTTP cache layer, but no SW cache).
});

// cacheFirst — return the cached response if present; otherwise
// fetch + store + return. Network failure on a cache-miss returns
// the rejected response so the page shows the same broken-image
// icon it would without a SW (don't lie about an asset existing).
async function cacheFirst(req) {
  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(req);
  if (cached) return cached;

  try {
    const resp = await fetch(req);
    // Only cache successful, complete responses. Opaque (cors: no-
    // cors), 4xx, 5xx all bypass the store — caching a 500 would
    // serve broken bundles forever.
    if (resp && resp.ok && resp.status === 200) {
      cache.put(req, resp.clone());
    }
    return resp;
  } catch (err) {
    // Network completely dead and no cached copy. Let the request
    // fail; nothing useful we can synthesize for a missing icon
    // or font.
    return Response.error();
  }
}

// ── Web Push hooks (kept commented; uncomment when push notifications
//     get wired up server-side) ─────────────────────────────────────
//
// self.addEventListener("push", async (event) => {
//   const { title, options } = await event.data.json();
//   event.waitUntil(self.registration.showNotification(title, options));
// });
//
// self.addEventListener("notificationclick", (event) => {
//   event.notification.close();
//   event.waitUntil(
//     clients.matchAll({ type: "window" }).then((clientList) => {
//       for (const client of clientList) {
//         const path = new URL(client.url).pathname;
//         if (path === event.notification.data.path && "focus" in client) {
//           return client.focus();
//         }
//       }
//       if (clients.openWindow) {
//         return clients.openWindow(event.notification.data.path);
//       }
//     })
//   );
// });
