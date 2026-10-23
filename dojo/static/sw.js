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
