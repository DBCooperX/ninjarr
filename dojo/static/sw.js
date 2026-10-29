// Dojo as an installed app. Browsers only run this on HTTPS (or localhost); on the usual
// http://<vm>:1337 the page simply works without it. Nothing is cached: Dojo shows live state,
// so every request goes to the network, and only a lost connection gets a short offline page.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", e => {
  if (e.request.mode !== "navigate") return;
  e.respondWith(fetch(e.request).catch(() => new Response(
    `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Dojo</title>
     <body style="background:#070707;color:#e6e6e6;font:16px system-ui;display:grid;place-items:center;height:100vh;margin:0;text-align:center">
     <div><p style="font-size:1.2rem;margin:0 0 8px">Dojo isn't reachable</p><p style="color:#8f8f8f;margin:0">Dojo only answers on your home network.<br>Connect to it, then pull down to retry.</p></div>`,
    { headers: { "Content-Type": "text/html; charset=utf-8" } })));
});

// Push notifications (Settings → Notifications on this device): Dojo encrypts each one for this
// browser; its push service delivers it even away from home. Tapping it opens Dojo on that page —
// which, like Dojo itself, only loads on the home network.
self.addEventListener("push", e => {
  let m = {};
  try { m = e.data ? e.data.json() : {}; } catch { m = { title: "Dojo", body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(m.title || "Dojo", {
    body: m.body || "", tag: m.tag || undefined, renotify: !!m.tag, data: { url: m.url || "/" },
    icon: "/static/icon-192.png", badge: "/static/badge.png",
  }));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "/", self.location.origin).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(list => {
    const w = list.find(c => c.url.startsWith(self.location.origin));
    if (w) return w.focus().then(c => (c || w).navigate ? (c || w).navigate(url) : null);
    return self.clients.openWindow(url);
  }));
});
