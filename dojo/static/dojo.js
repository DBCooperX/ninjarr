// Dojo's page code: plain JavaScript, no build step. The markup is templates/index.html.
"use strict";
const $ = (s, el = document) => el.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const app = $("#app");
let S = { session: null, page: "home", timers: [], base: [], dirty: false };

async function api(path, opts = {}) {
  const o = { headers: { "Content-Type": "application/json", "X-Dojo": "1" }, ...opts };
  if (o.body && typeof o.body !== "string") o.body = JSON.stringify(o.body);
  const r = await fetch(path, o);
  let data = {};
  try { data = await r.json(); } catch (_) {}
  if (r.status === 401 && path !== "/api/login") { boot(); throw new Error("signed out"); }
  if (!r.ok && data.ok === undefined) data.ok = false;
  return data;
}
function clearTimers() { [...S.timers, ...S.base].forEach(clearInterval); S.timers = []; S.base = []; if (S.es) { S.es.close(); S.es = null; S.live = false; } }
const brand = () => `<img class="brand-logo" src="/static/logo.png" alt="ninjarr">`;

// small building blocks
function toast(msg, kind = "ok") {
  const t = document.createElement("div");
  // "t-": a toast's kind must not collide with other classes (.info is the ⓘ button)
  t.className = `toast t-${kind}`; t.textContent = msg;
  $("#toasts").appendChild(t);
  setTimeout(() => t.remove(), kind === "fail" ? 7000 : 4000);
}
function ask({ title, body, ok = "OK" }) {
  return new Promise(res => {
    const d = $("#askdlg");
    $("#asktitle").textContent = title; $("#askbody").textContent = body || ""; $("#askok").textContent = ok;
    d.querySelectorAll("button").forEach(b => b.onclick = () => { d.close(); res(b.value === "yes"); });
    d.oncancel = () => res(false);
    d.showModal();
  });
}
const sk = (h, w = "100%") => `<div class="sk" style="height:${h}px;width:${w}"></div>`;
const info = text => `<button type="button" class="info" data-info aria-expanded="false" aria-label="More about this">i</button></p><p class="hint hidden">${text}`;
const plural = (n, one, many = one + "s") => `${n} ${n === 1 ? one : many}`;
function when(ts) {
  const x = new Date(ts * 1000), n = new Date(), y = new Date(n); y.setDate(n.getDate() - 1);
  const t = x.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  if (x.toDateString() === n.toDateString()) return `Today, ${t}`;
  if (x.toDateString() === y.toDateString()) return `Yesterday, ${t}`;
  return `${x.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" })}, ${t}`;
}
function stamp() { S.updated = Date.now(); fresh(); }
function fresh() {
  const el = $("#fresh"); if (!el) return;
  if (!S.updated) { el.textContent = ""; return; }
  const s = Math.round((Date.now() - S.updated) / 1000);
  const when = s < 10 ? "just now" : s < 60 ? `${s} s ago` : `${Math.round(s / 60)} min ago`;
  el.innerHTML = S.live && S.reload ? `<span class="live-dot" aria-hidden="true"></span>Live · updated ${when}` : `Updated ${when}`;
  el.title = S.live && S.reload ? "This page updates by itself when something happens in your apps" : "";
}
// Live updates: Dojo passes on what Sonarr, Radarr, Seerr and the players report; the open page
// reloads (once, shortly after a burst of events). The timers stay as a slow safety net.
function startLive() {
  if (S.es) S.es.close();
  if (!window.EventSource) return;
  const es = S.es = new EventSource("/api/events");
  es.onopen = () => { S.live = true; fresh(); };
  es.onerror = () => { S.live = false; fresh(); };
  es.onmessage = e => {
    let ev; try { ev = JSON.parse(e.data); } catch (_) { return; }
    if (ev.toast) toast(ev.toast, "info");
    clearTimeout(S.liveT);
    S.liveT = setTimeout(() => S.reload && !document.hidden && S.reload(), 1500);
  };
}
// a page's timer: every MS while not live, otherwise only as a 5-minute safety net
function poll(load, ms) {
  S.reload = load;
  S.timers.push(setInterval(() => { if (!S.live || Date.now() - (S.updated || 0) > 300000) load(); }, ms));
}

// ───────────────────────── start
// the installed app's service worker: browsers allow it on HTTPS only, so on http://<vm>:1337 this skips
if ("serviceWorker" in navigator && window.isSecureContext) navigator.serviceWorker.register("/sw.js").catch(() => {});
async function boot() {
  clearTimers();
  try { S.session = await (await fetch("/api/session")).json(); }
  catch (_) { app.innerHTML = gate(`<h1>Reconnecting…</h1><p class="lead">Dojo isn't answering, probably restarting. This page tries again by itself.</p>`); setTimeout(boot, 3000); return; }
  if (!S.session.authed) return S.session.setup ? showCode() : showLogin();
  if (S.session.setup) return setupWizard();
  shell();
}
const gate = inner => `<div class="gate">${brand()}${inner}</div>`;

function showCode() {
  app.innerHTML = gate(`
    <h1>Set up ninjarr</h1>
    <p class="lead">Type the six-digit code shown in your terminal.</p>
    <form id="f"><label class="field"><span>Setup code</span><input type="text" inputmode="numeric" autocomplete="one-time-code" id="code" maxlength="6" required></label>
    <button class="btn primary">Continue</button><p class="result fail" id="r"></p></form>`);
  $("#code").focus();
  $("#f").onsubmit = async e => {
    e.preventDefault();
    const d = await api("/api/login", { method: "POST", body: { code: $("#code").value } });
    d.ok ? boot() : ($("#r").textContent = d.message && /many/.test(d.message) ? d.message : "That code doesn't match. It's in the terminal, next to “code”.");
  };
}
function showLogin() {
  app.innerHTML = gate(`
    <h1>Sign in</h1>
    <p class="lead">Same login as Emby, Sonarr and the rest.</p>
    <form id="f"><label class="field"><span>Username</span><input type="text" id="u" autocomplete="username" required></label>
    <label class="field"><span>Password</span><input type="password" id="p" autocomplete="current-password" required></label>
    <button class="btn primary">Sign in</button><p class="result fail" id="r"></p></form>`);
  $("#u").focus();
  $("#f").onsubmit = async e => {
    e.preventDefault();
    const d = await api("/api/login", { method: "POST", body: { user: $("#u").value, password: $("#p").value } });
    d.ok ? boot() : ($("#r").textContent = d.message && /many/.test(d.message) ? d.message : "Username or password doesn't match.");
  };
}

// ───────────────────────── main shell
const PAGES = [["home", "Home"], ["stats", "Stats"], ["library", "Library"], ["settings", "Settings"], ["system", "System"]];
function shell() {
  app.innerHTML = `<div class="shell">
  <nav class="rail" aria-label="Dojo">
    <span class="logo" title="Dojo ${esc(S.session.version)}"><img src="/static/mark.png" alt="ninjarr"><small>v${esc(S.session.version)}</small></span>
    ${PAGES.map(([id, n]) => `<button data-p="${id}"><svg aria-hidden="true"><use href="#i-${id}"/></svg><span class="lbl">${n}</span></button>`).join("")}
    <span class="spacer"></span>
    <button id="logout"><svg aria-hidden="true"><use href="#i-out"/></svg><span class="lbl">Sign out</span></button>
  </nav>
  <div class="content">
    <header class="topbar"><h1 id="ptitle"></h1><span class="fresh" id="fresh"></span>
      <button class="jobpill" id="jobpill" hidden><span class="dot"></span><span id="jobpilltext">Working</span></button><span id="pact"></span></header>
    <main id="page"></main>
  </div></div>`;
  app.querySelectorAll(".rail [data-p]").forEach(b => b.onclick = () => go(b.dataset.p));
  $("#logout").onclick = async () => { await api("/api/logout", { method: "POST" }); history.replaceState(null, "", location.pathname); boot(); };
  $("#jobpill").onclick = () => S.lastJob && openJob(S.lastJob);
  S.base.push(setInterval(watchJobs, 4000), setInterval(fresh, 5000)); watchJobs(); startLive();
  go(location.hash.slice(1) || "home", "replace");
}
// how: "push" (a click), "replace" (first load), "pop" (the browser's back/forward), "stay" (re-render)
async function go(p, how = "push") {
  if (p.includes("/")) { const [page, sec] = p.split("/"); if (page === "stats" && sec === "system") S.stab = "system"; else S.openSection = sec; p = page; }
  const asked = p;
  if (!PAGES.some(([id]) => id === p)) p = "home";
  if (p !== asked && how !== "push") how = "replace";       // an old or unknown address: show the current one
  if (S.dirty && S.page === "settings" && p !== "settings") {
    if (!(await ask({ title: "Leave without saving?", body: "Your changes in Settings aren't saved yet.", ok: "Leave" }))) {
      if (how === "pop") history.pushState(null, "", "#settings");
      return;
    }
    S.dirty = false;
  }
  if (how === "push" && location.hash !== "#" + p) history.pushState(null, "", "#" + p);
  if (how === "replace") history.replaceState(null, "", "#" + p);
  const name = PAGES.find(([id]) => id === p)[1];
  const same = S.page === p && how === "stay";
  S.page = p;
  document.title = `${name} · Dojo`;
  $("#ptitle").textContent = name;
  app.querySelectorAll(".rail [data-p]").forEach(b => b.dataset.p === p ? b.setAttribute("aria-current", "page") : b.removeAttribute("aria-current"));
  S.timers.forEach(clearInterval); S.timers = []; S.reload = null;
  if (!same) { $("#pact").innerHTML = ""; S.updated = null; fresh(); window.scrollTo(0, 0); }
  $("#page").dataset.page = p;          // lets forms keep a reading width on wide screens
  ({ home: pageHome, library: pageLibrary, stats: pageStats, settings: pageSettings, system: pageSystem })[p]();
}
window.addEventListener("popstate", () => { if (S.session && S.session.authed && !S.session.setup && $("#page")) go(location.hash.slice(1), "pop"); });
window.addEventListener("beforeunload", e => { if (S.dirty) { e.preventDefault(); e.returnValue = ""; } });

async function watchJobs() {
  // a newer Dojo is running (after an update): load it, unless there are unsaved changes
  try {
    const now = await (await fetch("/api/session")).json();
    if (S.session.build && now.build && now.build !== S.session.build) {
      if (!S.dirty && !$("#jobdlg").open) { location.reload(); return; }
      if (S.dirty && !S.toldReload) { S.toldReload = true; toast("Dojo was updated. Save or discard, then reload the page.", "info"); }
    }
  } catch (_) {}
  const jobs = await api("/api/jobs").catch(() => null);
  if (!jobs) return;
  const live = jobs.find(j => j.status === "running" || j.status === "queued");
  const pill = $("#jobpill");
  if (!pill) return;
  pill.hidden = !live;
  if (live) { S.lastJob = live.id; $("#jobpilltext").textContent = jobLabel(live.cmd) + "…"; }
}
const jobLabel = c => ({ apply: "Applying settings", wire: "Re-applying settings", update: "Updating", backup: "Backing up", doctor: "Running the full check", "fix-imports": "Fixing stuck imports", "drive-finish": "Connecting Google Drive", "restore-drive": "Restoring from Google Drive" })[c.split(" ")[0]]
  || (c.startsWith("restart") ? `Restarting ${c.split(" ")[1]}` : c.startsWith("restore") ? "Restoring"
    : c.startsWith("try-version") ? `Trying ${APPNAME[c.split(" ")[1]] || c.split(" ")[1]} ${c.split(" ")[2]}`
    : c.startsWith("revert-version") ? `Going back to the previous ${APPNAME[c.split(" ")[1]] || c.split(" ")[1]}` : c);

async function runJob(cmd) {
  if (cmd === "reboot" && !(await ask({ title: "Restart the machine now?", ok: "Restart",
      body: "Everything stops for about a minute, including anything playing. Dojo reconnects by itself." }))) return null;
  const d = await api("/api/jobs", { method: "POST", body: { cmd } });
  if (!d.ok) { toast(d.message || "That didn't start.", "fail"); return null; }
  openJob(d.id, jobLabel(cmd)); watchJobs();
  return d.id;
}

// a short job without the log window; resolves to true when it went through
async function quietJob(cmd) {
  const d = await api("/api/jobs", { method: "POST", body: { cmd } }).catch(() => ({ ok: false }));
  if (!d.ok) { toast(d.message || "That didn't start.", "fail"); return false; }
  for (let i = 0; i < 60; i++) {
    await new Promise(r => setTimeout(r, 1000));
    const j = await api(`/api/jobs/${d.id}`).catch(() => null);
    if (j && (j.status === "ok" || j.status === "failed")) return j.status === "ok";
  }
  return false;
}

// ───────────────────────── job log
// The log keeps bootstrap's terminal colours (256-colour codes): turned into styled spans here,
// built with textContent so nothing in the log is ever read as HTML.
function xterm(n) {
  if (n < 16) return ["#000", "#c33", "#3c3", "#cc3", "#36c", "#c3c", "#3cc", "#ccc", "#666", "#f66", "#6f6", "#ff6", "#69f", "#f6f", "#6ff", "#fff"][n];
  if (n >= 232) { const v = 8 + 10 * (n - 232); return `rgb(${v},${v},${v})`; }
  const c = n - 16, l = [0, 95, 135, 175, 215, 255];
  return `rgb(${l[Math.floor(c / 36)]},${l[Math.floor(c / 6) % 6]},${l[c % 6]})`;
}
function ansiRenderer() {
  let fg = null, bg = null, bold = false;
  const sgr = codes => {
    for (let i = 0; i < codes.length; i++) {
      const c = codes[i];
      if (c === 0) { fg = bg = null; bold = false; }
      else if (c === 1) bold = true;
      else if (c === 22) bold = false;
      else if (c === 39) fg = null;
      else if (c === 49) bg = null;
      else if ((c === 38 || c === 48) && codes[i + 1] === 5) { const col = xterm(codes[i + 2] || 0); if (c === 38) fg = col; else bg = col; i += 2; }
      else if (c >= 30 && c <= 37) fg = xterm(c - 30); else if (c >= 90 && c <= 97) fg = xterm(c - 82);
    }
  };
  return { render(text) {
    const frag = document.createDocumentFragment();
    // a carriage return redraws the line in a terminal: keep what's after the last one
    text = text.split("\n").map(l => l.includes("\r") ? l.slice(l.lastIndexOf("\r") + 1) : l).join("\n");
    // lines of the banner's block art sit tight (no line gap), so its pixels join up
    let prevArt = false;
    for (const [n, line] of text.split("\n").entries()) {
      const art = /[▀▄█]/.test(line);
      if (n && !art && !prevArt) frag.append("\n");
      prevArt = art;
      const box = art ? document.createElement("span") : frag;
      if (art) box.className = "art";
      const re = /\x1b\[([0-9;]*)([A-Za-z])/g;
      let last = 0, m;
      const put = s => { if (!s) return; if (!fg && !bg && !bold) { box.append(s); return; }
        const sp = document.createElement("span"); sp.textContent = s;
        if (fg) sp.style.color = fg; if (bg) sp.style.background = bg; if (bold) sp.style.fontWeight = "700"; box.append(sp); };
      while ((m = re.exec(line))) {
        put(line.slice(last, m.index)); last = re.lastIndex;
        if (m[2] === "m") sgr(m[1] === "" ? [0] : m[1].split(";").map(Number));
      }
      put(line.slice(last));
      if (art) frag.append(box);
    }
    return frag;
  } };
}
let jobPoll = null;
function openJob(id, title, onDone) {
  const dlg = $("#jobdlg"), log = $("#joblog");
  $("#jobtitle").textContent = title || "Job";
  log.textContent = ""; let offset = 0, waitSince = null; const ansi = ansiRenderer();
  clearInterval(jobPoll);
  const tick = async () => {
    let d;
    try {
      const r = await fetch(`/api/jobs/${id}?offset=${offset}`, { headers: { "X-Dojo": "1" } });
      if (r.status === 401) { clearInterval(jobPoll); $("#jobstate").textContent = "Signed out. Close this and sign in again."; $("#jobclose").onclick = () => { $("#jobdlg").close(); boot(); }; return; }
      d = await r.json();
    }
    catch (_) { $("#jobstate").textContent = "Dojo is restarting as part of this. Reconnecting…"; return; }
    if (d.log) { const atEnd = log.scrollTop + log.clientHeight >= log.scrollHeight - 30; log.append(ansi.render(d.log)); if (atEnd) log.scrollTop = log.scrollHeight; }
    if (d.offset !== undefined) offset = d.offset;
    if (!title) $("#jobtitle").textContent = jobLabel(d.cmd || "");
    const st = d.status || "starting";
    if (st !== "queued") waitSince = null; else waitSince = waitSince || Date.now();
    const stuck = st === "queued" && Date.now() - waitSince > 30000;
    $("#jobstate").innerHTML = stuck ? `<span class="state-failed">The server hasn't started this. Its job runner isn't running: on the server, run <code>sudo ./bootstrap.sh</code> once, then try again.</span>`
      : `<span class="state-${esc(st)}">${{ queued: "Waiting for the server to start it", running: "Running", ok: "Done", failed: "Stopped with a problem. The log says where." }[st] || esc(st)}</span>`;
    if (st === "ok" || st === "failed") {
      clearInterval(jobPoll); watchJobs(); onDone && onDone(st);
      if (!S.session.setup) { toast(`${$("#jobtitle").textContent}: ${st === "ok" ? "done" : "stopped with a problem"}`, st === "ok" ? "ok" : "fail"); if (S.page) go(S.page, "stay"); }
    }
  };
  jobPoll = setInterval(tick, 1000); tick();
  $("#jobclose").onclick = () => { clearInterval(jobPoll); dlg.close(); watchJobs(); };
  if (!dlg.open) dlg.showModal();
}

// ───────────────────────── home
const CHAIN = [
  ["Request", "Seerr", ["Seerr", "Playback/Seerr signed in through Emby"]],
  ["Search", "Prowlarr", ["Prowlarr", "Search/Indexers"]],
  ["Grab", "Sonarr · Radarr", ["Sonarr", "Radarr", "Streaming chain/Sonarr → AIOStreams", "Streaming chain/Radarr → AIOStreams",
    "Streaming chain/Sonarr library folder", "Streaming chain/Radarr library folder"]],
  ["Stream", "AIOStreams", ["AIOStreams", "Streaming chain/Sonarr sees the AIOStreams library", "Streaming chain/Radarr sees the AIOStreams library"],
    { iptv: ["AIOStreams · Dispatcharr", ["Live TV/Dispatcharr channels", "Live TV/Dispatcharr", "Live TV/Emby's tuner"]] }],
  ["Play", "Emby · Bazarr", ["Emby", "Bazarr", "Playback/Emby libraries", "Playback/Subtitle providers"]],
];
function fixButton(f) {
  if (!f) return "<span></span>";
  if (f.job) return `<button class="btn" data-job="${esc(f.job)}">${esc(f.label)}</button>`;
  if (f.go) return `<button class="btn" data-goto="${esc(f.go)}">${esc(f.label)}</button>`;
  if (f.open) return `<a class="btn" href="${esc(lanUrl(f.open) + (f.path || ""))}" target="_blank" rel="noopener">${esc(f.label)}</a>`;
  return "<span></span>";
}
// go to a page and open one of its sections ("settings/indexers")
function goTo(where) { const [page, sec] = where.split("/"); S.openSection = sec; go(page); }
const CHAIN_APP = { Request: "Seerr", Search: "Prowlarr", Grab: "Sonarr", Stream: "AIOStreams", Play: "Emby" };
// apps by port on the address this page was opened with; the public name when Caddy serves it
const lanUrl = port => `http://${location.hostname}:${port}`;

// Drill-down: an item opens the page in the app it comes from (a series in Sonarr, a request in
// Seerr…). src(link, html) takes a link from the server; at(app, path, html) builds one here.
const PORTS = { Sonarr: 8989, Radarr: 7878, Prowlarr: 9696, Seerr: 5055, Emby: 8096, AIOStreams: 3000, Dispatcharr: 9191 };
const src = (l, html) => l ? `<a class="src" href="${esc(lanUrl(l.port) + (l.path || ""))}" target="_blank" rel="noopener" title="Open in ${esc(l.app)}">${html}</a>` : html;
const at = (app, path, html) => src({ port: PORTS[app], path, app }, html);
// the app's icon, passed on by Dojo (so it also shows when Dojo is opened over HTTPS)
// the apps' own icons, through Dojo; Dojo's is its own, and Caddy (which has none to ask for) gets a padlock: it does the HTTPS
function appIcon(name, src = name.toLowerCase() === "dojo" ? "/static/mark.png" : `/api/appicon/${name.toLowerCase()}`) {
  if (name.toLowerCase() === "caddy") return `<svg class="appicon" viewBox="0 0 24 24" aria-hidden="true"><path d="M8 11V8a4 4 0 0 1 8 0v3" fill="none" stroke="#22b638" stroke-width="2.4" stroke-linecap="round"/><rect x="4.5" y="10.5" width="15" height="11" rx="2.5" fill="#22b638"/><circle cx="12" cy="15.4" r="1.7" fill="#0c0a09"/><path d="M12 16.5v2.2" stroke="#0c0a09" stroke-width="1.6" stroke-linecap="round"/></svg>`;
  if (!src) return `<span class="appicon letter" aria-hidden="true">${esc(name[0])}</span>`;
  return `<img class="appicon" src="${esc(src)}" alt=""
    onerror="this.outerHTML='<span class=&quot;appicon letter&quot; aria-hidden=&quot;true&quot;>${esc(name[0])}</span>'">`;
}
function appsPanel(a) {
  if (!a || !a.apps) return "";
  const icon = id => `<svg aria-hidden="true"><use href="#i-${id}"/></svg>`;
  const tile = x => `<div class="tile">
      <a class="aname" href="${esc(lanUrl(x.port))}" target="_blank" rel="noopener">${appIcon(x.name, x.icon)}<span><b>${esc(x.name)}</b><span>${esc(x.job)}</span></span></a>
      <div class="alinks">
        <a class="lk" href="${esc(lanUrl(x.port))}" target="_blank" rel="noopener" title="At home">${icon("house")}${esc(location.hostname)}:${x.port}</a>
        ${x.remote ? `<a class="lk ${x.home_only ? "" : "remote"}" href="${esc(x.remote)}" target="_blank" rel="noopener" title="${x.home_only ? "HTTPS, home network only" : "From anywhere"}">${icon(x.home_only ? "house" : "globe")}${esc(x.remote.replace("https://", ""))}</a>` : ""}
      </div></div>`;
  return `<h2>Your apps</h2><div class="tiles">${a.apps.filter(x => x.name !== "Dojo").map(tile).join("")}</div>
    <p class="note">${a.user ? `Sign in to each as <b>${esc(a.user)}</b> with your ninjarr password. ` : ""}${a.domain
      ? `<span class="where">${icon("house")} address at home</span> · <span class="where remote">${icon("globe")} address from anywhere, over HTTPS</span>`
      : `These addresses work on your home network only. Add a domain in Settings → Away from home to reach Emby, Seerr and AIOStreams from outside.`}</p>`;
}
// Now playing: a card per stream (poster, who, where, how far, how it plays)
function playingCards(now) {
  return `<div class="playing">${now.map(x => {
    const art = x.art ? `style="--art:url('/api/art/${esc(x.art)}')"` : "";
    const how = x.via === "livetv" ? "live TV" : x.method;
    return `<div class="pcard" ${art} title="${esc(howWords(how).long)}">${poster(x.art, "poster", x.grp)}
      <div class="pc-b"><a href="#stats" class="wlink pc-t" data-home-title="${esc(x.grp || "")}" data-home-via="${esc(x.via || "")}">${esc(x.title)}</a>
        <div class="pc-w">${avatar(x.user, x.user_id, "avatar sm")}${esc(x.user)}${x.paused ? `<span class="muted">&nbsp;· paused</span>` : ""}</div>
        <div class="pc-d">${esc([x.client, x.device].filter((v, i, l) => v && l.indexOf(v) === i).join(" on "))}</div>
        <div class="pc-f">${x.pct != null ? `<span class="pbar"><span style="width:${x.pct}%"></span></span>` : `<span style="flex:1"></span>`}${howTag(how)}</div></div></div>`;
  }).join("")}</div>`;
}
function shelf(items) {
  if (items.length < 4) return `<div class="fewnew">${items.map(x => `<a class="fn" href="${esc(lanUrl(x.link.port) + x.link.path)}" target="_blank" rel="noopener" title="Open in Emby">
      ${poster(x.art, "poster", x.title)}<span><span class="sh-t">${esc(x.title)}</span><span class="sh-s">${esc(x.sub || (x.kind === "movie" ? "movie" : ""))}</span></span></a>`).join("")}</div>`;
  return `<div class="shelf">${items.map(x => `<a href="${esc(lanUrl(x.link.port) + x.link.path)}" target="_blank" rel="noopener" title="Open in Emby">
      ${poster(x.art, "poster", x.title)}<div class="sh-t">${esc(x.title)}</div><div class="sh-s">${esc(x.sub || (x.kind === "movie" ? "movie" : ""))}</div></a>`).join("")}</div>`;
}
async function pageHome() {
  const el = $("#page");
  el.innerHTML = `<div class="sk-stack">${sk(230)}${sk(24, "24%")}${sk(140)}${sk(24, "24%")}${sk(200)}</div>`;
  const load = async () => {
    const [d, a, h] = await Promise.all([api("/api/health").catch(() => null), api("/api/apps").catch(() => null), api("/api/home").catch(() => null)]);
    if (!d || !d.checks) { el.innerHTML = `<div class="empty"><h3>Can't run the health checks</h3><p>Dojo couldn't check your apps just now. It tries again in 30 seconds.</p></div>`; return; }
    stamp();
    const by = k => d.checks.find(c => c.label === k || `${c.group}/${c.label}` === k);
    const appOf = n => ((a && a.apps) || []).find(x => x.name === n);
    const links = CHAIN.map(([what, who, keys, extra]) => {
      if (extra && extra.iptv && a && a.iptv) { who = extra.iptv[0]; keys = keys.concat(extra.iptv[1]); }
      const st = keys.map(by).filter(Boolean).map(c => c.status);
      const s = st.includes("fail") ? "fail" : st.includes("warn") ? "warn" : st.length ? "ok" : "off";
      return { what, who, s, app: appOf(CHAIN_APP[what]), apps: who.split(" · ").map(n => ({ n, port: appOf(n)?.port })) };
    });
    const fails = d.checks.filter(c => c.status === "fail"), warns = d.checks.filter(c => c.status === "warn");
    const broken = links.find(l => l.s === "fail");
    const verdict = fails.length ? `${broken ? `The ${broken.what.toLowerCase()} step` : "Something"} is broken` : warns.length ? "Working, with a few things to look at" : "Everything works";
    const sub = fails.length ? esc(fails[0].label + (fails[0].detail ? ": " + fails[0].detail : ""))
      : `${d.checks.length} health checks on your apps and the VM, ${warns.length ? `${warns.length} need${warns.length === 1 ? "s" : ""} attention` : "all passing"}`;
    const groups = [...new Set(d.checks.map(c => c.group))];
    const row = c => `<div class="item ${c.status}"><span class="mark" aria-label="${c.status}"></span>
          <div><h3>${esc(c.label)}</h3>${c.detail ? `<div class="detail">${esc(c.detail)}</div>` : ""}</div>
          ${fixButton(c.fix)}</div>`;
    const attention = [...fails, ...warns];
    const now = (h && h.now) || [], recent = (h && h.recent) || [], wk = (h && h.week) || {}, tr = (h && h.traffic) || {};
    const stuck = (h && h.stuck) || [];
    const art = (now.find(x => x.art) || recent.find(x => x.art) || {}).art;
    const node = l => `<div class="node">${l.app ? appIcon(l.app.name, l.app.icon) : ""}<span class="st" aria-hidden="true"></span></div>`;
    el.innerHTML = `
      <section class="hero" ${art ? `style="--art:url('/api/art/${esc(art)}?w=big')"` : ""}>
        <div class="hero-top"><div><p class="verdict ${fails.length ? "fail" : ""}">${verdict}</p><p class="hero-sub">${sub}</p>
          ${now.length ? "" : `<p class="hero-idle"><svg aria-hidden="true"><use href="#i-play"/></svg>Nobody's watching right now</p>`}</div>
          ${wk.plays || tr.streamed_mb ? `<div class="week">${wk.plays ? `<div><b>${hrs(wk.hours)}</b><span>watched in the last 7 days</span></div><div><b>${wk.plays}</b><span>${wk.plays === 1 ? "time" : "times"} something was played</span></div><div><b>${wk.viewers}</b><span>${wk.viewers === 1 ? "person" : "people"} watched</span></div>` : ""}${tr.streamed_mb ? `<div><b>${gbTxt(tr.streamed_mb)}</b><span>sent to players today${tr.fetched_mb != null ? ` · ${gbTxt(tr.fetched_mb)} downloaded from usenet for it` : ""}</span></div>` : ""}</div>` : ""}</div>
        <div class="chain" role="list" aria-label="The streaming chain">${links.map(l => `
          <div class="link ${l.s}" role="listitem" aria-label="${l.what}: ${l.s}">${l.app
            ? `<a class="step" href="${lanUrl(l.app.port)}" target="_blank" rel="noopener" title="Open ${CHAIN_APP[l.what]}">${node(l)}<div class="what">${l.what}</div></a>`
            : `${node(l)}<div class="what">${l.what}</div>`}
            <div class="who">${l.apps.map(x => x.port ? `<a href="${lanUrl(x.port)}" target="_blank" rel="noopener" title="Open ${esc(x.n)}">${esc(x.n)}</a>` : esc(x.n)).join(" · ")}</div></div>`).join("")}</div>
      </section>
      ${now.length ? `<div class="sec-h"><h2>Playing right now</h2><a href="#stats" data-goto="stats">Details</a></div>${playingCards(now)}` : ""}
      ${recent.length ? `<div class="sec-h"><h2>Recently added</h2><a href="${esc(lanUrl(8096))}" target="_blank" rel="noopener">Open Emby</a></div>${shelf(recent)}` : ""}
      ${stuck.length ? `<div class="sec-h"><h2>Imports</h2></div><div class="checks">${stuck.map(importRow).join("")}</div>` : ""}
      ${attention.length ? `<div class="home-grid">
        <div><h2>Needs your attention</h2><div class="checks">${attention.map(row).join("")}</div></div>
        <div>${appsPanel(a)}</div>
      </div>` : `<div class="apps-wide">${appsPanel(a)}</div>`}
      <details class="more" ${S.openChecks ? "open" : ""}><summary>All ${d.checks.length} health checks${attention.length ? "" : " · all passing"}</summary>
      ${groups.map(g => `<div class="group-title">${esc(g)}</div><div class="checks">${d.checks.filter(c => c.group === g).map(row).join("")}</div>`).join("")}
      </details>`;
    el.querySelectorAll("[data-job]").forEach(b => b.onclick = () => runJob(b.dataset.job));
    el.querySelectorAll("[data-goto]").forEach(b => b.onclick = e => { e.preventDefault();
      if (b.dataset.goto === "stats") { S.stab = "watching"; W.view = "stats"; } goTo(b.dataset.goto); });
    el.querySelectorAll("[data-home-title]").forEach(b => b.onclick = e => { e.preventDefault();
      if (!b.dataset.homeTitle) return goTo("stats");
      S.stab = "watching"; W.from = "stats"; W.view = "title"; W.grp = b.dataset.homeTitle; W.via = b.dataset.homeVia; go("stats"); });
    $("details.more", el).ontoggle = e => { S.openChecks = e.target.open; };
  };
  await load();
  poll(load, 30000);
}

// A download Sonarr/Radarr finished but didn't import, and where ninjarr's fix for broken file
// names is with it (lib/namefix.sh); shown on Home only while there's one, or one was just fixed
function importRow(r) {
  const App = r.app === "radarr" ? "Radarr" : "Sonarr", port = r.app === "radarr" ? 7878 : 8989;
  const open = { open: port, path: "/activity/queue", label: `Open ${App}` };
  const what = `${App} · ${r.files} ${r.files === 1 ? "file" : r.app === "radarr" ? "files" : "episodes"}`;
  const mins = m => m < 1 ? "under a minute" : m === 1 ? "1 min" : m < 90 ? `${m} min` : `${Math.round(m / 60)} h`;
  const them = r.files === 1 ? "it" : "them";
  let st = "warn", detail, fix = null;
  switch (r.state) {
    case "broken":
      detail = `${what} · some file names are broken, so ${App} can't import ${them}. ninjarr imports ${them} by hand `
        + (r.fix_in_min > 0 ? `in about ${mins(r.fix_in_min)}` : "at its next check") + ".";
      fix = { job: "fix-imports", label: "Fix now" }; break;
    case "linked":
      detail = `${what} · ninjarr put ${r.linked === 1 ? "the file" : `${r.linked} files`} in the library by hand and is waiting for ${App} to pick ${them} up. The download leaves the queue by itself.`; break;
    case "gaveup":
      st = "fail"; detail = `${what} · some files never showed up in ${App}. Use Manual Import there, or remove it from the queue with "Blocklist release" ticked.`;
      fix = open; break;
    case "names-ok":
      if ((r.age_min || 0) < 30) { st = "ok"; detail = `${what} · moving into the library for ${mins(r.age_min || 0)}.`; break; }
      detail = `${what} · stuck for ${mins(r.age_min)}. Its file names are fine, so it's something else${r.why ? `: ${r.why}` : `, ${App}'s queue says what`}.`;
      fix = open; break;
    case "fixed":
      st = "ok"; detail = `${App} · fixed ${mins(r.ago_min)} ago: ${r.files ? `${r.files} ${r.files === 1 ? "file" : "files"} imported by hand` : "it was all in already"}.`; break;
    default:
      st = "ok"; detail = `${what} · moving into the library${r.why ? `: ${r.why}` : "."}`;
  }
  return `<div class="item ${st}"><span class="mark" aria-label="${st}"></span>
    <div><h3>${esc(r.title)}</h3><div class="detail">${esc(detail)}</div></div>${fixButton(fix)}</div>`;
}

// one sentence on what to do about the transcodes that are running
function transcodeHint(sessions) {
  const t = sessions.filter(x => x.how === "transcoding");
  const r = t.flatMap(x => x.reasons).join(" ");
  const devices = [...new Set(t.map(x => x.device))].join(", ");
  if (/codec/.test(r) && t.some(x => /AV1/.test(x.source))) return `${devices} can't play AV1, so Emby converts it. New grabs avoid AV1; older AV1 files get replaced over time.`;
  if (/HDR|Dolby Vision/.test(r)) return `${devices} can't show this HDR format, so Emby converts it and colours can look washed out. A device with HDR support plays it directly.`;
  if (/bitrate/.test(r)) return `The file needs more bandwidth than ${devices} or the connection allows, so Emby makes a smaller version. Raise the quality limit in the Emby app's playback settings.`;
  if (/subtitles/.test(r)) return `${devices} can't show these subtitles, so Emby paints them into the picture. A text subtitle (SRT) plays without converting.`;
  return `${devices} can't play this file as it is, so Emby converts it. Emby does that on the CPU unless the VM has a GPU and Emby Premiere.`;

}

// ───────────────────────── Library (requests and the library) and Stats (watching, history, timeline)
// a page's period, remembered in this browser (a convenience: without it, the page starts at 7d)
const pref = (k, d) => { try { return localStorage.getItem("dojo." + k) || d; } catch (_) { return d; } };
const setPref = (k, v) => { try { localStorage.setItem("dojo." + k, v); } catch (_) {} };
const periodSeg = opts => `<div class="seg" role="group" aria-label="Period">${opts.map(x => `<button data-w="${x}" aria-pressed="${x === S.win}">${x === "all" ? "All" : x}</button>`).join("")}</div>`;
function bindLibButtons(el) {
  el.querySelectorAll("[data-libs]").forEach(b => b.onclick = async () => {
    if (b.dataset.confirm === "replace" && !(await ask({ title: "Replace the broken files?",
        body: "Each release with missing parts or gone from usenet goes on Sonarr's or Radarr's blocklist, so it's never grabbed again. Its file is removed and a search starts for another release. Until one is found, the title shows under “Not found yet”.", ok: "Replace" }))) return;
    b.disabled = true;
    const rs = await Promise.all(b.dataset.libs.split(" ").map(x => api(`/api/library/${x}`, { method: "POST" }).catch(() => ({ ok: false }))));
    const ok = rs.every(r => r.ok);
    toast(ok ? (rs.map(r => r.message).filter(m => m && !/^(Nothing|Everything)/.test(m)).join(" ") || "Asked Sonarr and Radarr. Results show up in Stats → Timeline.") : (rs.find(r => !r.ok).message || "That didn't work."), ok ? "ok" : "fail");
    b.disabled = false;
  });
}
async function pageLibrary() {
  const el = $("#page");
  S.win = pref("period.library", "7d");
  if (!["24h", "7d", "30d"].includes(S.win)) S.win = "7d";
  const head = () => `<div class="subnav"><p class="pagelead">What people asked for, what arrived, and whether the files in your library play well.</p>${periodSeg(["24h", "7d", "30d"])}</div>`;
  const bindHead = () => el.querySelectorAll("[data-w]").forEach(b => b.onclick = () => { setPref("period.library", b.dataset.w); pageLibrary(); });
  S.timers.forEach(clearInterval); S.timers = [];
  el.innerHTML = head() + `<div class="sk-stack">${sk(40, "50%")}${sk(140)}${sk(220)}</div>`; bindHead();
  const load = async () => {
    const html = await overview();
    if (html == null) return;
    stamp(); el.innerHTML = head() + html; bindHead(); bindLibButtons(el);
  };
  await load();
  poll(load, 60000);
}
async function pageStats() {
  const el = $("#page");
  S.stab = S.stab || "watching";
  S.win = pref("period.stats", "7d");
  if (!["24h", "7d", "30d", "90d", "all"].includes(S.win)) S.win = "7d";
  S.swin = pref("period.system", "24h") === "7d" ? "7d" : "24h";
  const tabs = [["watching", "Watching"], ["history", "History"], ["timeline", "Timeline"]];
  const tab = ([k, n]) => `<button data-stab="${k}" aria-pressed="${S.stab === k}">${n}</button>`;
  const head = () => {
    const period = S.stab === "watching" && (W.view === "stats" || W.view === "person");
    // streaming on the left; the VM itself apart, on its own
    return `<div class="subnav"><div class="stabs"><div class="seg" role="group" aria-label="Streaming">${tabs.map(tab).join("")}</div>
      <div class="seg seg-sys" role="group" aria-label="The server">${tab(["system", "Server"])}</div></div>
      ${period ? periodSeg(["24h", "7d", "30d", "90d", "all"]) : ""}
      ${S.stab === "system" ? `<div class="seg" role="group" aria-label="Period">${["24h", "7d"].map(x => `<button data-sw="${x}" aria-pressed="${x === S.swin}">${x}</button>`).join("")}</div>` : ""}</div>`;
  };
  const bindHead = () => {
    el.querySelectorAll("[data-stab]").forEach(b => b.onclick = () => { S.stab = b.dataset.stab; if (!["timeline", "system"].includes(S.stab)) W.view = S.stab === "history" ? "history" : "stats"; pageStats(); });
    el.querySelectorAll("[data-w]").forEach(b => b.onclick = () => { setPref("period.stats", b.dataset.w); pageStats(); });
    el.querySelectorAll("[data-sw]").forEach(b => b.onclick = () => { setPref("period.system", b.dataset.sw); pageStats(); });
  };
  S.timers.forEach(clearInterval); S.timers = [];
  el.innerHTML = head() + `<div class="sk-stack">${sk(76)}${sk(30, "45%")}${sk(140)}${sk(120)}</div>`; bindHead();
  const load = async () => {
    if (!["timeline", "system"].includes(S.stab)) S.stab = W.view === "history" ? "history" : W.view === "stats" ? "watching" : S.stab;
    const html = S.stab === "timeline" ? await timeline() : S.stab === "system" ? await systemStats() : await watching();
    if (html == null) return;
    stamp();
    el.innerHTML = head() + html; bindHead();
    el.querySelectorAll("[data-tlf]").forEach(b => b.onclick = () => { S.tlf = b.dataset.tlf; load(); });
    if (S.stab === "system") bindCharts(el);
    else if (S.stab !== "timeline") bindWatching(el, load);
  };
  await load();
  poll(load, S.stab === "timeline" ? 15000 : 60000);
}
// what's playing in detail (Stats → Watching): every session, where it streams from, how it plays
function nowPanel(n) {
  const lt = n.livetv;                      // null without Live TV
  const live = lt && lt.ok ? lt.channels : [];
  const logins = lt && lt.ok ? lt.logins.filter(x => x.max) : [];
  if (!(n.viewers || n.streams || live.length)) return "";
  const via = x => { const nm = x.via === "dispatcharr" ? "Dispatcharr" : "AIOStreams";
    return at(nm, x.via === "dispatcharr" ? "/stats" : "/dashboard/streams/active", `<span class="via via-${x.via}">${appIcon(nm)}${nm}</span>`); };
  return `<h2 class="first">Right now</h2><div class="now">
      <div><b>${n.viewers}</b><span>${n.viewers === 1 ? "stream" : "streams"} playing in Emby${n.viewers ? ` · ${n.transcoding} of them converted by Emby` : ""}</span></div>
      <div><b>${n.mbps} MB/s</b><span>downloading from usenet for ${plural(n.streams, "stream")}</span></div>
      <div><b>${n.connections} / ${n.connections_max}</b><span>${at("AIOStreams", "/dashboard/usenet", "usenet connections")} in use (your plan's limit)</span></div>
      ${lt && lt.ok ? `<div><b>${live.length}</b><span>live TV ${live.length === 1 ? "channel" : "channels"} playing${logins.length ? ` · ${logins.reduce((a, x) => a + x.used, 0)} of ${logins.reduce((a, x) => a + x.max, 0)} IPTV streams in use` : ""}</span></div>`
        : `<div><b>${n.has_backup ? (n.backup_share_pct ?? 0) + "%" : "–"}</b><span>${n.has_backup ? "of usenet articles came from the backup provider" : "no backup provider set up"}</span></div>`}
    </div>
    ${n.sessions.length ? `<div class="tablewrap" style="margin-top:12px"><table><thead><tr><th>Who</th><th>Playing</th><th>Comes from</th><th>File</th><th>How it plays</th><th>Bitrate</th></tr></thead><tbody>
      ${n.sessions.map(x => `<tr><td>${esc(x.user)}<div class="meta small">${esc(x.device)}</div></td><td>${src(x.link, esc(x.title))}${x.paused ? ` <span class="meta">paused</span>` : ""}</td>
        <td>${via(x)}</td>
        <td class="num">${esc(x.source || "–")}</td>
        <td><span class="${x.how === "transcoding" ? "meh" : x.how === "direct play" ? "good" : ""}" title="${esc(howWords(x.how).long)}">${esc(howWords(x.how).short)}</span>${x.hw === false ? ` <span class="meta">on the CPU</span>` : x.hw ? ` <span class="meta">on the GPU</span>` : ""}
          ${x.reasons.length ? `<div class="meta small">${x.reasons.map(esc).join("; ")}</div>` : ""}</td>
        <td class="num">${x.mbps != null ? x.mbps + " Mbit/s" : "–"}</td></tr>`).join("")}</tbody></table></div>` : ""}
    ${n.sessions.some(x => x.how === "transcoding" && x.via !== "dispatcharr") ? `<p class="note">${transcodeHint(n.sessions.filter(x => x.via !== "dispatcharr"))}</p>` : ""}
    ${live.length ? `<h3 class="sub">Live TV through Dispatcharr</h3><div class="tablewrap"><table><thead><tr><th>Channel</th><th>Watched on</th><th>Quality</th><th>IPTV login</th></tr></thead><tbody>
      ${live.map(c => `<tr><td>${at("Dispatcharr", "/stats", esc(c.name))}${c.healthy === false ? ` <span class="meh">· stalling</span>` : ""}<div class="meta small">for ${c.minutes} min</div></td>
        <td>${c.watchers.length ? c.watchers.map(w => esc(w.app)).join(", ") : plural(c.clients, "viewer")}<div class="meta small">${c.watchers.map(w => esc(w.ip)).filter(Boolean).join(", ")}</div></td>
        <td class="num">${esc(c.quality || "–")}${c.kbps ? `<div class="meta small">${(c.kbps / 1000).toFixed(1)} Mbit/s</div>` : ""}</td>
        <td>${c.login ? at("Dispatcharr", "/sources", esc(c.login)) : "–"}</td></tr>`).join("")}</tbody></table></div>` : ""}
    ${logins.length > 1 && live.length ? `<p class="note">Streams in use per IPTV login: ${logins.map(x => `${esc(x.name)} <b>${x.used} of ${x.max}</b>`).join(" · ")}</p>` : ""}
    ${n.has_backup && n.backup_share_pct >= 15 ? `<p class="note"><span class="meh">${n.backup_share_pct}% of usenet articles come from the backup provider.</span>
 Your main provider is missing more articles than usual.</p>` : ""}`;
}
async function overview() {
  const d = await api(`/api/stack?window=${S.win}`).catch(() => null);
  if (!d || !d.flow) return `<div class="empty"><h3>Couldn't collect the numbers</h3><p>One of the apps isn't answering. Home shows which.</p></div>`;
  const f = d.flow, L = d.library, H = d.healing;
  const span = { "24h": "24 hours", "7d": "7 days", "30d": "30 days" }[S.win];
  const w = (x, of) => of ? Math.max(2, Math.round(100 * x / of)) : 0;
  const mins = m => m == null ? "–" : m < 90 ? `${m} min` : m < 2880 ? `${Math.round(m / 60)} h` : `${Math.round(m / 1440)} days`;
  const bar = (label, sub, val, of, cls = "") => `<div class="bar"><span class="label">${label}${sub ? `<small>${sub}</small>` : ""}</span>
      <span class="track"><span class="fill ${cls}" style="width:${w(val, of)}%"></span></span><span class="n">${val}</span></div>`;
  const pctTxt = (p, good, meh) => p == null ? "–" : `<span class="${p >= good ? "good" : p >= meh ? "meh" : "bad"}">${p}%</span>`;

  const lt = d.livetv;
  const ltNote = !lt || lt.ok ? "" : `<p class="note">${{ "no-key": "Connect Dojo to Dispatcharr in Settings → Live TV to see live TV in Dojo.",
      rejected: "Dispatcharr turned down Dojo's API key. Connect again in Settings → Live TV.", down: "Dispatcharr isn't answering." }[lt.reason] || ""}</p>`;
  const hasData = f.requested || f.grabs || d.indexers.length || H.failed || L.files;
  if (!hasData) return `<h2 class="first">Last ${span}</h2>
    <div class="empty"><h3>Nothing to measure yet</h3><p>Request something in Seerr. Numbers show up here as it moves through the stack.</p>
    <p><a class="btn" href="${lanUrl(5055)}" target="_blank" rel="noopener">Open Seerr</a></p></div>`;

  const headline = f.requested
    ? `${f.available} of ${plural(f.requested, "request")} can be watched now${f.minutes_to_play_median != null ? `, usually ${mins(f.minutes_to_play_median)} after the request` : ""}`
    : `No requests in the last ${span}`;
  return `${L.files ? libraryPanel(L, span) : ""}
    <h2>Requests in the last ${span}</h2>
    ${f.requested ? `<p class="verdict sm">${headline}</p>` : `<p class="muted" style="margin:0">None in this period.</p>`}
    ${f.requested ? `<div class="funnel" style="margin-top:14px">
      ${bar("Requested", `in ${at("Seerr", "/requests", "Seerr")}`, f.requested, f.requested)}
      ${bar("Ready to watch", `in ${at("Emby", "/web/index.html", "Emby")}`, f.available, f.requested, "ok")}
      ${bar("Watched", "played at least once", f.watched, f.requested, "ok")}
    </div>` : ""}
    <p class="note">Sonarr and Radarr picked ${plural(f.grabs, "release")} · ${f.imports} landed in the library · ${f.failed} failed${f.minutes_to_play_worst != null ? ` · slowest request took ${mins(f.minutes_to_play_worst)}` : ""}
      · the full history is in ${at("Sonarr", "/activity/history", "Sonarr")} and ${at("Radarr", "/activity/history", "Radarr")}</p>
    ${f.stuck.length ? `<h2>Requests waiting over 2 hours</h2><div class="panel"><ul class="list">${f.stuck.map(x => `<li><span>${src(x.link, esc(x.title))}${x.by ? ` <span class="meta">· requested by ${esc(x.by)}</span>` : ""}</span><span class="meta">${esc(x.status)} · ${x.age_h} h</span></li>`).join("")}</ul></div>
      <p class="note">“No release found yet” usually means nothing in your language or quality exists yet. Sonarr and Radarr keep looking.</p>` : ""}
    ${d.indexers.length ? `<h2>Indexers</h2><div class="tablewrap"><table><thead><tr><th>Indexer</th><th>Releases picked</th><th>Became a file</th><th>Complete on usenet</th></tr></thead><tbody>
      ${d.indexers.map(r => `<tr><td>${at("Prowlarr", "/indexers", esc(r.indexer.replace(/ \(Prowlarr\)$/, "")))}</td><td class="num">${at("Prowlarr", "/history", r.grabs)}</td>
        <td class="num">${r.imported} · ${pctTxt(r.landed_pct, 90, 75)}</td>
        <td class="num">${r.complete_pct == null ? "–" : at("AIOStreams", "/dashboard/usenet/stats", pctTxt(r.complete_pct, 95, 85))}${r.dead_on_arrival ? ` <span class="meta">${r.dead_on_arrival} already gone</span>` : ""}</td></tr>`).join("")}</tbody></table></div>
      <p class="note">Which indexer the releases came from. <b>Became a file</b>: how many of the picked releases ended up in the library. <b>Complete on usenet</b>: how many AIOStreams' nightly check found whole, with no parts missing; “already gone” ones were removed from usenet before they could play.${
        d.indexers.every(r => r.complete_pct == null) && d.indexer_check ? ` <span class="meh">${d.indexer_check.aio == null ? "AIOStreams didn't answer, so Complete on usenet is empty."
          : `None of these releases could be matched to AIOStreams' library (${d.indexer_check.aio} releases there), so Complete on usenet is empty.`}</span>` : ""}</p>` : ""}
    ${H.failed ? `<h2>Self-healing</h2>
    <p class="lead-s">Releases that broke (failed to download or vanished from usenet) and whether Sonarr and Radarr found a replacement by themselves.</p>
    <div class="panel"><ul class="list">
      <li><span>Releases that broke</span><span class="count">${H.failed}</span></li>
      <li><span>Replaced by themselves</span>
<span class="count ${H.replaced === H.failed ? "good" : ""}">${H.replaced}</span></li>
      <li><span>Still waiting for a replacement${H.waiting.length ? `<div class="small muted">${H.waiting.map(x => src(x.link, esc(x.title))).join(", ")}</div>` : ""}</span><span class="count ${H.waiting_count ? "meh" : ""}">${H.waiting_count}</span></li>
    </ul></div>` : ""}
    ${ltNote}`;
}
// ───────────────────────── Watching: Dojo's own watch history
// Views: stats (the period at a glance), history (every play, filterable), a person, a title.
const W = { view: "stats", page: 1, q: "", kind: "", user: "", why: "", metric: "plays", top: "series", rank: "hours" };
// one meaning per colour: what was watched in colour; how it played in greys, with conversion in amber
const SER = { Episodes: "var(--s1)", Movies: "var(--s2)", "Live TV": "var(--s3)", "Direct play": "var(--n1)", "Direct stream": "var(--n2)", Transcode: "var(--warn)", File: "var(--n1)", "On screen": "var(--n2)" };
const HOWN = { "Direct play": "Played as is", "Direct stream": "Repackaged", Transcode: "Converted" };
const dayOf = t => new Date(t * 1000).toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });
const hrs = h => h == null ? "–" : h >= 100 ? `${Math.round(h)} h` : h >= 1 ? `${h} h` : `${Math.round(h * 60)} min`;
const mins = s => s >= 3600 ? `${Math.floor(s / 3600)} h ${Math.round((s % 3600) / 60)} min` : `${Math.max(1, Math.round(s / 60))} min`;
const initials = n => esc((n || "?").replace(/[^\p{L}\p{N} ]/gu, "").split(/\s+/).filter(Boolean).slice(0, 2).map(x => x[0]).join("").toUpperCase() || "?");
const poster = (id, cls = "poster", label = "") => id
  ? `<span class="${cls}"><img src="/api/art/${esc(id)}" alt="" loading="lazy" onerror="this.parentNode.classList.add('none');this.remove()"><span class="ph">${initials(label)}</span></span>`
  : `<span class="${cls} none"><span class="ph">${initials(label)}</span></span>`;
const avatar = (name, id, cls = "avatar") => id
  ? `<span class="${cls}"><img src="/api/art/${esc(id)}?user=1" alt="" loading="lazy" onerror="this.parentNode.classList.add('none');this.remove()"><span class="ph">${initials(name)}</span></span>`
  : `<span class="${cls} none"><span class="ph">${initials(name)}</span></span>`;
const toPerson = name => `<a href="#stats" class="wlink" data-wperson="${esc(name)}">${esc(name)}</a>`;
const toTitle = (grp, via, text) => `<a href="#stats" class="wlink" data-wtitle="${esc(grp)}" data-wvia="${esc(via || "")}">${text ?? esc(grp)}</a>`;
// how a play reached the player, in plain words: Emby's own terms ("direct play", "transcoding") mean little to most people
const HOW = {
  "direct play": ["Plays as is", "The player plays the file as it is. Nothing is converted."],
  "direct stream": ["Repackaged", "Emby repacks the file into a container the player opens. Picture and sound stay untouched; almost no work for the server."],
  "transcoding": ["Converted", "The player can't play the file as it is, so Emby converts the video while you watch. That's real work for the server."],
  "audio transcoding": ["Sound converted", "Emby converts only the sound for this player. The picture plays untouched; little work for the server."],
  "live TV": ["Live TV", "A live TV channel."],
};
const howWords = m => { const x = HOW[m]; return x ? { short: x[0], long: x[1] } : { short: m || "", long: "" }; };
const howTag = m => !m ? "" : `<span class="how how-${m === "direct play" ? "dp" : m === "direct stream" ? "ds" : m === "live TV" ? "live" : "tc"}" title="${esc(howWords(m).long)}">${esc(howWords(m).short)}</span>`;

// a column chart in SVG: stacked series (2px surface gap between segments), 4px rounded data end,
// hairline grid, one hover target per column with every series in the tooltip
function colChart(cfg) {
  const legend = cfg.series.length > 1 ? `<div class="legend">${cfg.series.map(s => `<span><i style="background:${s.color}"></i>${esc(s.name)}</span>`).join("")}</div>` : "";
  return `${legend}<div class="chart" data-chart='${esc(JSON.stringify(cfg))}'><div class="tip" hidden></div></div>`;
}
// draws a chart at its container's real width, so text and bars stay crisp at any size
function drawChart({ labels, series, height = 180, unit = "", suffix = "", every, grouped = false }, width) {
  const n = labels.length, W0 = Math.max(240, width), H0 = height, L = 34, B = 22, T = 8;
  const totals = labels.map((_, i) => grouped ? Math.max(...series.map(s => s.values[i] || 0)) : series.reduce((a, s) => a + (s.values[i] || 0), 0));
  const max = Math.max(...totals, 0);
  const nice = v => { if (v <= 0) return 1; const p = 10 ** Math.floor(Math.log10(v)), f = v / p; return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * p; };
  const top = nice(max), band = (W0 - L) / n, bw = Math.min(24, Math.max(3, band * (grouped ? 0.7 / series.length : 0.62)));
  const col = (x, y0, y1, color, round) => { const hgt = Math.max(0, y0 - y1), r = round ? Math.min(4, hgt, bw / 2) : 0;
    return r ? `<path d="M${x},${y0} V${y1 + r} Q${x},${y1} ${x + r},${y1} H${x + bw - r} Q${x + bw},${y1} ${x + bw},${y1 + r} V${y0} Z" fill="${color}"/>`
             : `<rect x="${x}" y="${y1}" width="${bw}" height="${hgt}" fill="${color}"/>`; };
  const y = v => T + (H0 - T - B) * (1 - v / top);
  const fmt = v => unit === "h" ? (v >= 10 ? Math.round(v) : Math.round(v * 10) / 10) + " h" : v >= 1000 ? (v / 1000).toFixed(1) + "K" : Math.round(v * 10) / 10;
  let g = "";
  for (const t of [0, top / 2, top]) g += `<line x1="${L}" x2="${W0}" y1="${y(t)}" y2="${y(t)}" class="${t ? "grid" : "base"}"/><text x="${L - 6}" y="${y(t) + 4}" class="tick" text-anchor="end">${fmt(t)}</text>`;
  const step = every ? Math.max(every, Math.ceil(n / Math.floor(W0 / 44))) : Math.max(1, Math.ceil(n / Math.floor(W0 / 64)));
  labels.forEach((lab, i) => {
    const cx = L + band * i + band / 2;
    if (grouped) {
      const w = series.length * bw + (series.length - 1) * 2;
      series.forEach((s, j) => { const v = s.values[i] || 0; if (v > 0) g += col(cx - w / 2 + j * (bw + 2), y(0), y(v), s.color, true); });
    } else {
      let acc = 0;
      const segs = series.map(s => ({ s, v: s.values[i] || 0 })).filter(x => x.v > 0);
      segs.forEach((x, j) => {        // 2px surface gap between stacked segments, rounded end on the top one
        const y0 = y(acc) - (j ? 2 : 0), y1 = y(acc + x.v); acc += x.v;
        if (y0 > y1) g += col(cx - bw / 2, y0, y1, x.s.color, j === segs.length - 1);
      });
    }
    if (i % step === 0) g += `<text x="${cx}" y="${H0 - 6}" class="tick" text-anchor="middle">${esc(lab)}</text>`;
    const tip = JSON.stringify({ t: lab, rows: series.map(s => [s.name, fmt(s.values[i] || 0) + suffix, s.color]), total: series.length > 1 && !grouped ? fmt(totals[i]) + suffix : null });
    g += `<rect class="hit" x="${L + band * i}" y="${T}" width="${band}" height="${H0 - T - B}" data-tip='${esc(tip)}' tabindex="0"/>`;
  });
  return `<svg viewBox="0 0 ${W0} ${H0}" width="${W0}" height="${H0}" role="img" aria-label="${esc(series.map(s => s.name).join(", "))}">${g}</svg>`;
}
function bindCharts(root) {
  root.querySelectorAll(".chart").forEach(c => {
    const tip = $(".tip", c);
    const cfg = JSON.parse(c.dataset.chart);
    const draw = () => { c.querySelector("svg")?.remove(); c.insertAdjacentHTML("afterbegin", drawChart(cfg, c.clientWidth)); };
    draw();
    if (window.ResizeObserver) { let w = c.clientWidth; new ResizeObserver(() => { if (Math.abs(c.clientWidth - w) > 8) { w = c.clientWidth; draw(); } }).observe(c); }
    const show = e => {
      const h = e.target.closest("[data-tip]"); if (!h) return;
      const d = JSON.parse(h.dataset.tip);
      tip.replaceChildren();
      const head = document.createElement("div"); head.className = "tip-h"; head.textContent = d.t; tip.append(head);
      for (const [name, v, col] of d.rows) {
        const row = document.createElement("div"); row.className = "tip-r";
        const k = document.createElement("i"); k.style.background = col;
        const b = document.createElement("b"); b.textContent = v;
        const s = document.createElement("span"); s.textContent = name;
        row.append(k, b, s); tip.append(row);
      }
      if (d.total) { const t = document.createElement("div"); t.className = "tip-t"; t.textContent = `Total ${d.total}`; tip.append(t); }
      tip.hidden = false;
      const r = c.getBoundingClientRect(), hr = h.getBoundingClientRect();
      const x = Math.min(Math.max(hr.left - r.left + hr.width / 2 - tip.offsetWidth / 2, 0), r.width - tip.offsetWidth);
      tip.style.left = `${x}px`; tip.style.top = `${Math.max(0, hr.top - r.top - tip.offsetHeight - 6)}px`;
      c.querySelectorAll(".hit.on").forEach(x => x.classList.remove("on")); h.classList.add("on");
    };
    c.onpointermove = show; c.onfocusin = show;
    c.onpointerleave = () => { tip.hidden = true; c.querySelectorAll(".hit.on").forEach(x => x.classList.remove("on")); };
  });
}
// one-series horizontal bars (players, people): label, bar, value
const hbars = (items, val, label) => { const m = Math.max(...items.map(val), 0.01);
  return `<div class="hb">${items.map(x => `<div class="hb-r"><span class="hb-l">${label(x)}</span><span class="hb-t"><span style="width:${Math.max(2, 100 * val(x) / m)}%"></span></span><span class="hb-v">${hrs(val(x))}</span></div>`).join("")}</div>`; };
const r1 = x => Math.round(x * 10) / 10;
const heatGrid = (heat, byDay = heat.map(r => r1(r.reduce((a, v) => a + v, 0) / 60)), byHour = heat[0].map((_, h) => r1(heat.reduce((a, r) => a + r[h], 0) / 60))) => {
  const m = Math.max(1, ...heat.flat()), days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  const dm = Math.max(0.01, ...byDay), hm = Math.max(0.01, ...byHour);
  return `<div class="heat">${"<span></span>" + Array.from({ length: 24 }, (_, h) => `<span class="h">${h % 3 === 0 ? h : ""}</span>`).join("") + `<span class="h">total</span>`}
    ${heat.map((row, i) => `<span>${days[i]}</span>${row.map((v, h) => `<span class="c" title="${days[i]} ${h}:00–${h + 1}:00 · ${v} min watched" style="opacity:${v ? (0.18 + 0.82 * v / m).toFixed(2) : 0.06}"></span>`).join("")}
      <span class="tot" title="${days[i]}: ${hrs(byDay[i])}"><span style="width:${Math.max(2, 34 * byDay[i] / dm).toFixed(1)}px"></span><b>${hrs(byDay[i])}</b></span>`).join("")}
    <span></span>${byHour.map((v, h) => `<span class="htot" title="${h}:00–${h + 1}:00: ${hrs(v)} in all"><span style="height:${100 * v / hm}%"></span></span>`).join("")}<span></span></div>`; };

async function watching() {
  if (W.view === "person") return watchPerson();
  if (W.view === "title") return watchTitle();
  if (W.view === "history") return watchHistory();
  const [st, now] = await Promise.all([watchStats(), api("/api/now").catch(() => null)]);
  return st == null ? null : (now && now.sessions ? nowPanel(now) : "") + st;
}

// Why Emby converts, heaviest first, in plain words: what happened, how much work it is for the
// server, and what you can do about it. A row opens those plays in History.
const LOAD = { heavy: ["meh", "Heavy for the server"], light: ["good", "Light for the server"], setting: ["", "Caused by a setting"] };
function reasonHelp(reason) {
  const r = reason.toLowerCase();
  const rules = [
    [/subtitle/, "heavy", "These subtitles are pictures (usually from a Blu-ray) that the player can't show, so Emby paints them into the video while you watch.",
      "Pick text subtitles (SRT) instead, or let Bazarr fetch them."],
    [/audio channels/, "light", "The sound has more channels than the player handles (for example 7.1 on a stereo TV), so Emby mixes it down. The picture plays untouched.",
      "Nothing to do; it costs almost nothing."],
    [/audio/, "light", "The player can't play this sound format (often DTS or TrueHD), so Emby converts only the sound. The picture plays untouched.",
      "If a soundbar or receiver is connected, turn on audio passthrough in the player's settings."],
    [/file type/, "light", "The player can't open this kind of file, so Emby repacks it into one it can. Nothing is re-encoded.",
      "Nothing to do; it costs almost nothing."],
    [/bitrate/, "setting", "The file needs more bandwidth than the player is allowed to use, so Emby makes a smaller version.",
      "In the Emby app's playback settings, set quality to Auto or Maximum. Away from home, your internet upload speed may be the limit."],
    [/hdr/, "heavy", "The screen can't show this kind of HDR (often Dolby Vision), so Emby converts the picture to normal colours. Colours can look flat.",
      "Turn on tone mapping in Emby → Transcoding for better colours, or play it on a screen that supports HDR."],
    [/resolution/, "heavy", "The player can't show this resolution (usually 4K), so Emby shrinks the picture while you watch.",
      "Play 4K titles on a 4K device."],
    [/video codec/, "heavy", "The player can't decode the file's video format (often AV1), so Emby re-encodes the whole picture while you watch.",
      "Library → Picture → Look for better swaps AV1 files for a format most players handle."],
    [/./, "heavy", "The video is encoded in a way this player can't handle (for example 10-bit or an unusual profile), so Emby re-encodes the picture while you watch.",
      "Usually only fixed by a different version of the file or a newer player."],
  ];
  const [, load, what, help] = rules.find(([re]) => re.test(r));
  return { load, what, help };
}
function reasonsTable(reasons) {
  return `<div class="tablewrap"><table class="rtable"><thead><tr><th>Reason</th><th>Plays</th><th>Players</th><th>What happens</th><th>What helps</th></tr></thead>
<tbody>
    ${reasons.map(x => { const h = reasonHelp(x.reason), [cls, label] = LOAD[h.load];
      return `<tr data-why="${esc(x.reason)}" tabindex="0" title="Show these plays in History"><td>${esc(x.reason[0].toUpperCase() + x.reason.slice(1))}</td><td class="num">${x.n}</td>
        <td>${esc(x.players.join(", "))}${x.more_players ? ` <span class="muted">+${x.more_players}</span>` : ""}</td>
        <td><span class="${cls}">${label}.</span> <span class="muted">${esc(h.what)}</span></td><td class="muted"><b class="rlabel">What helps: </b>${esc(h.help)}</td></tr>`; }).join("")}
  </tbody></table></div>`;
}

// Stats → System: the VM itself — not what's being watched. Right now, the last day or week,
// each app against its memory ceiling and where it's heading, and DNS pile-ups if there were any.
const gbTxt = mb => mb == null ? "–" : mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${Math.round(mb)} MB`;
function spark(values, top) {
  const w = 132, h = 30, n = values.length, max = Math.max(top || 0, ...values.map(v => v || 0), 1);
  let d = "", pen = false;
  values.forEach((v, i) => {
    if (v == null) { pen = false; return; }
    const x = (n > 1 ? i / (n - 1) : 0) * (w - 2) + 1, y = h - 2 - (h - 4) * v / max;
    d += `${pen ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`; pen = true;
  });
  return `<svg class="spark" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" aria-hidden="true">
    ${top ? `<line x1="0" x2="${w}" y1="2" y2="2" class="ceil"/>` : ""}<path d="${d}"/></svg>`;
}
function trendTxt(t) {
  if (t.state === "collecting") return `<span class="muted">still measuring · trend in about ${t.left_h} h</span>`;
  if (t.state === "steady") return `<span class="muted">steady${Math.abs(t.per_day) >= 20 ? ` · ${t.per_day > 0 ? "+" : ""}${gbTxt(t.per_day)} a day` : ""}</span>`;
  const left = t.to_limit_days == null ? "" : t.to_limit_days < 0.5 ? " · reaches its limit within hours" : t.to_limit_days < 1.5 ? " · reaches its limit in about a day" : ` · reaches its limit in about ${Math.round(t.to_limit_days)} days`;
  return `<span class="${t.to_limit_days != null && t.to_limit_days <= 7 ? "meh" : "muted"}">grows ${gbTxt(t.per_day)} a day${left}</span>`;
}
async function systemStats() {
  const d = await api(`/api/system?window=${S.swin}`).catch(() => null);
  if (!d) return null;
  if (!d.sampled) return `<div class="empty"><h3 class="sub">No readings yet</h3><p>The server (the VM ninjarr runs on) measures itself every 5 minutes; the first numbers show here shortly after an update.</p></div>`;
  const N = d.now, used = N.mem_total_mb - N.mem_avail_mb, span = S.swin === "7d" ? "7 days" : "24 hours";
  const dpct = N.disk_size_mb ? Math.round(100 * N.disk_used_mb / N.disk_size_mb) : null;
  const dk = d.disk.state === "filling" ? (d.disk.to_full_days <= 90 ? `<span class="meh">full in about ${d.disk.to_full_days} days</span>` : `+${gbTxt(d.disk.per_day)} a day`)
    : d.disk.state === "steady" ? "not filling up" : "";
  const wait = N.wait_some, waitCls = wait >= 10 ? "meh" : "";
  const unit = S.swin === "7d" ? "3 hours" : "half hour";
  const chart = (title, cfg, cap) => `<div><h3 class="sub">${title}</h3><div class="panel wchart">${colChart({ labels: d.labels, height: 150, ...cfg })}<p class="cap">${cap}</p></div></div>`;
  const one = (name, k) => [{ name, color: "var(--s1)", values: d.series[k] }];
  const dns = d.dns, oom = d.oom.filter(o => Date.now() / 1000 - o.at < 7 * 86400);
  const vol = mb => mb >= 1048576 ? `${(mb / 1048576).toFixed(1)} TB` : gbTxt(mb);
  const net = n => n ? `<span title="received · sent">↓ ${vol(n.in)} · ↑ ${vol(n.out)}</span>` : "–";
  return `
    <p class="lead-s">The machine ninjarr runs on (a VM): how busy it is and how much memory each app uses. What's being watched is under Watching.</p>
    <div class="now">
      <div><b>${N.cpu_pct == null ? "–" : Math.round(N.cpu_pct) + "%"}</b><span>CPU busy right now${N.cores ? ` · ${N.cores} cores` : ""}</span></div>
      <div><b>${gbTxt(used)}</b><span>of ${gbTxt(N.mem_total_mb)} memory in use</span></div>
      <div><b class="${waitCls}">${wait == null ? "–" : (wait < 0.1 ? "0" : wait.toFixed(1)) + "%"}</b><span>of the last minute apps waited for memory · near 0 is healthy</span></div>
      ${N.swap_mb ? `<div><b>${gbTxt(N.swap_used_mb)}</b><span>of ${gbTxt(N.swap_mb)} swap in use (memory moved to disk)</span></div>` : ""}
      ${dpct != null ? `<div><b>${dpct}%</b><span>of the ${gbTxt(N.disk_size_mb)} disk full${dk ? ` · ${dk}` : ""}</span></div>` : ""}
    </div>
    <div class="wfacts">
      ${d.net_mb ? `<span>The server received <b>${vol(d.net_mb.in)}</b> and sent <b>${vol(d.net_mb.out)}</b> in the last ${span}</span>` : ""}
      <span>Each app has a memory limit; together they add up to <b>${gbTxt(d.ceilings_mb)}</b> of <b>${gbTxt(N.mem_total_mb)}</b>. That's fine: they rarely all peak at once</span>
      ${oom.length ? `<span class="meh">${plural(oom.length, "app")} hit ${oom.length === 1 ? "its" : "their"} memory limit and ${oom.length === 1 ? "was" : "were"} restarted this week</span>` : ""}
      ${dns.piles_7d ? `<span class="meh">Name lookups (DNS) piled up ${plural(dns.piles_7d, "time")} this week</span>` : ""}
    </div>

    <div class="wchap"><h2 class="chap">Over ${span}</h2></div>
    <div class="wgrid">
      ${chart("Memory in use", { unit: "", suffix: " GB", series: one("In use", "mem") }, `The highest point in each ${unit}, in GB, out of ${gbTxt(N.mem_total_mb)}.`)}
      ${chart("Waiting for memory", { suffix: "%", series: one("Waiting", "wait") }, `How much of the time apps were stuck waiting for memory (the worst 5 minutes in each ${unit}). Near 0 is healthy; it climbs when the server runs short, before it freezes.`)}
      ${chart("CPU", { suffix: "%", series: one("CPU", "cpu") }, `How busy the processor was, on average in each ${unit}, all cores together. Emby converting a video shows up here.`)}
      ${chart("Network", { suffix: " GB", grouped: true, series: [{ name: "Received", color: "var(--s1)", values: d.series.in }, { name: "Sent", color: "var(--s2)", values: d.series.out }] },
        `GB in and out of the server in each ${unit}: streams to your players, usenet downloads, everything.`)}
    </div>

    <div class="wchap"><h2 class="chap">Apps</h2></div>
    <div class="tablewrap"><table class="ptable systable"><thead><tr><th>App</th><th>Memory · limit</th><th class="sp-c">Memory, last ${span}</th><th class="tr-c">Trend</th><th>CPU</th><th>Data in · out <span class="muted">${span}</span></th></tr></thead><tbody>
      ${d.apps.map(a => `<tr><td>${appIcon(a.label)}${esc(a.label)}</td>
        <td class="memc"><div class="mem-t"><b>${gbTxt(a.mb)}</b>${a.limit_mb ? `<span class="muted"> of ${gbTxt(a.limit_mb)}</span>` : ""}</div>
          ${a.limit_mb ? `<span class="hb-t"><span style="width:${Math.min(100, Math.max(2, 100 * a.mb / a.limit_mb))}%${a.mb > 0.85 * a.limit_mb ? ";background:var(--warn)" : ""}"></span></span>` : ""}
          <div class="tr-m small">${trendTxt(a.trend)}</div></td>
        <td class="sp-c">${spark(a.spark, a.limit_mb)}</td><td class="tr-c">${trendTxt(a.trend)}</td>
        <td class="num">${a.cpu == null ? "–" : Math.round(a.cpu) + "%"}</td><td class="num netc">${net(a.net)}${a.traffic && a.traffic.some(v => v) ? spark(a.traffic).replace('class="spark"', 'class="spark spark-net"') : ""}</td></tr>`).join("")}
    </tbody></table></div>
    <p class="cap"><b>Memory · limit</b>: what the app uses now, out of the most it may use; past its limit an app is restarted. The line shows the last ${span}, with the limit as the dashed top.
      <b>Trend</b>: whether the app's memory keeps creeping up, judged from the lowest it drops back to over two days or more.
      <b>CPU</b>: at the last reading; 100% is one full core.
      <b>Data in · out</b>: what the app received (↓) and sent (↑) in the last ${span}. AIOStreams' ↓ is what it downloaded from usenet, Emby's ↑ what went out to your players.</p>

    ${dns.piles_7d ? `<div class="wchap"><h2 class="chap">DNS pile-ups</h2></div>
    <p class="lead-s">Apps find each other and the internet through name lookups (DNS), which Docker answers. When too many wait at once, they fail until Docker catches up, and apps briefly can't reach each other. It often comes with memory running short: compare with Waiting for memory above.</p>
    <div class="wgrid"><div class="tablewrap"><table class="ptable"><thead><tr><th>Day</th><th>Pile-ups</th></tr></thead><tbody>
      ${dns.days.map(x => `<tr><td>${esc(x.day)}</td><td class="num">${x.n}</td></tr>`).join("")}</tbody></table></div>
      ${dns.names.length ? `<div class="tablewrap"><table class="ptable"><thead><tr><th>Name looked up during them</th><th>Used by</th><th>Times</th></tr></thead><tbody>
      ${dns.names.map(x => `<tr><td>${esc(x.name)}</td><td class="muted">${esc(x.who || "–")}</td><td class="num">${x.n}</td></tr>`).join("")}</tbody></table></div>` : ""}</div>` : ""}

    <p class="note">Measured every 5 minutes and kept for 7 days${d.since ? `, since ${esc(when(d.since))}` : ""}. Last reading ${esc(when(d.sampled))}.</p>`;

}

async function watchStats() {
  const d = await api(`/api/watching?window=${S.win}`).catch(() => null);
  if (!d) return null;
  if (!d.ok) return `<div class="empty"><h3 class="sub">No watch history</h3><p>${esc(d.message || "")}</p></div>`;
  const T = d.totals, C = d.cards;
  const span = { "24h": "the last 24 hours", "7d": "the last 7 days", "30d": "the last 30 days", "90d": "the last 90 days", all: "all time" }[S.win];
  const since = `Recorded since ${esc(when(d.since))}.${T.from_log ? ` ${plural(T.from_log, "play")} in this period came from Emby's activity log (start and stop only, so no pauses or stream details).` : ""}`;
  if (!T.plays) return `<div class="empty"><h3 class="sub">Nothing watched in ${span}</h3><p>${since} Plays of a minute or more count — in Emby, and straight from Dispatcharr.</p></div>`;

  // 1 · Overview: the numbers, the top titles (one card, switchable), people, the last play
  const kinds = [["series", "Series"], ["movies", "Movies"], ["channels", "Live TV"]].filter(([k]) => C[k].hours.length);
  if (!kinds.some(([k]) => k === W.top)) W.top = (kinds[0] || [])[0];
  const tops = W.top ? C[W.top][W.rank] : [];
  const metric = x => W.rank === "viewers" ? `${plural(x.viewers, "viewer")} · ${hrs(x.hours)}`
    : `${hrs(x.hours)} · ${W.top === "series" ? plural(x.plays, "episode") : plural(x.viewers, "viewer")}`;
  const seg = (attr, cur, opts, label) => `<div class="seg sm" role="group" aria-label="${label}">${opts.map(([k, n]) => `<button ${attr}="${k}" aria-pressed="${cur === k}">${n}</button>`).join("")}</div>`;
  const people = C.people, pmax = Math.max(...people.map(x => x.hours), 0.01);

  // 2 · When: the hour-by-hour grid with its totals along the edges
  const labels = d.by_time.map(b => b.label);
  const kindsT = ["Episodes", "Movies", "Live TV"].filter(k => d.by_time.some(b => b[W.metric][k]));
  const unit = d.step === 3600 ? "hour" : d.step === 86400 ? "day" : "week";

  // 3 · Playback: folded unless opened (remembered), with a one-line summary on the fold
  const hows = ["Direct play", "Direct stream", "Transcode"].filter(k => d.by_time.some(b => b.how[k]));
  const heavy = d.reasons.find(x => reasonHelp(x.reason).load === "heavy");
  const pbSum = [`Emby converted ${T.transcode_pct}% of the watch time`, d.devices.length && plural(d.devices.length, "player"),
    heavy && `mostly because ${heavy.reason.replace(/^the device /, "it ")}`].filter(Boolean).join(" · ");

  return `
    <div class="now">
      <div><b>${hrs(T.hours)}</b><span>watched in ${span}</span></div>
      <div><b>${T.plays}</b><span>${T.plays === 1 ? "time" : "times"} something was played · ${plural(T.titles, "different title")}</span></div>
      <div><b>${T.viewers}</b><span>${T.viewers === 1 ? "person" : "people"} watched</span></div>
      <div><b>${T.peak}</b><span>most plays at the same time${T.peak_at ? ` · ${esc(when(T.peak_at))}` : ""}</span></div>
    </div>
    <div class="wfacts">
      ${T.live_pct ? `<span><b>${T.live_pct}%</b> of the time was live TV</span>` : ""}
      ${T.finished_pct != null ? `<span><b>${T.finished_pct}%</b> of episodes and movies were watched to the end</span>` : ""}
      ${T.paused_h ? `<span><b>${hrs(T.paused_h)}</b> on pause</span>` : ""}
      ${d.longest ? `<span>Longest single play <b>${hrs(d.longest.hours)}</b> · ${esc(d.longest.user)}, ${esc(d.longest.title)}</span>` : ""}
    </div>

    <div class="wover">
    ${kinds.length ? `<section class="wtop">
      <div class="wsec-h"><h2>Top ${esc((kinds.find(([k]) => k === W.top) || [, ""])[1].toLowerCase())}</h2>
        <div class="wtop-c">${kinds.length > 1 ? seg("data-wtop", W.top, kinds, "Kind") : ""}${seg("data-wrank", W.rank, [["hours", "Most time"], ["viewers", "Most people"]], "Rank by")}</div></div>
      <ol class="tops">${tops.map((x, i) => `<li><span class="tops-p">${poster(x.art, "poster", x.name)}<span class="rank">${i + 1}</span></span>
        <span class="tops-n" title="${esc(x.name)}">${toTitle(x.name, x.via)}</span><span class="tops-m">${metric(x)}</span></li>`).join("")}</ol>
    </section>` : ""}

    <div class="wgrid wpeople">
      <div><h2>People</h2><div class="panel plist">${people.map(x => `<div class="pl-r">${avatar(x.name, x.user_id, "avatar")}
          <div class="pl-b"><div class="pl-t">${toPerson(x.name)}<span class="muted">${hrs(x.hours)} · ${plural(x.plays, "play")}</span></div>
          <span class="hb-t"><span style="width:${Math.max(2, 100 * x.hours / pmax)}%"></span></span></div></div>`).join("")}</div></div>
      ${d.last ? `<div><h2>Latest play</h2><div class="wlast">${poster(d.last.art, "poster", d.last.title)}<div class="wl-b">
        <div class="wl-t">${toTitle(d.last.grp || d.last.title, d.last.via, esc(d.last.title))}</div>
        <div class="wl-m">${avatar(d.last.user, d.last.user_id, "avatar sm")}${toPerson(d.last.user)}</div><div class="wl-w">${esc(when(d.last.when))}</div></div></div></div>` : ""}
    </div>
    </div>

    <div class="wchap"><h2 class="chap">When</h2></div>
    <div class="wwhen"><div>
    <div class="wsec-h"><h3 class="sub">Over time</h3>${seg("data-wmetric", W.metric, [["plays", "Plays"], ["hours", "Hours"]], "Measure")}</div>
    <div class="panel wchart">${colChart({ labels, unit: W.metric === "hours" ? "h" : "", series: kindsT.map(k => ({ name: k, color: SER[k], values: d.by_time.map(b => b[W.metric][k]) })) })}
      <p class="cap">${W.metric === "plays" ? "How often something was played" : "Hours watched"} per ${unit}, split into episodes, movies and live TV.</p></div></div>
    <div><div class="wsec-h"><h3 class="sub">Hour by hour</h3></div>
    <div class="panel" style="padding:14px 16px">${heatGrid(d.heat, d.weekday, d.hour)}<p class="cap">Each square is one hour of one weekday; the darker, the more was watched then. Hours per weekday on the right, per time of day along the bottom.</p></div></div>
    </div>

    <details class="wchap pb" ${pref("stats.playback") === "open" ? "open" : ""}><summary><h2 class="chap">Playback</h2><span class="muted">${esc(pbSum)}</span></summary>
      <div class="wgrid">
        ${hows.length ? `<div><h3 class="sub">How it plays</h3><div class="panel wchart">${colChart({ labels, unit: "h", height: 160, series: hows.map(k => ({ name: HOWN[k], color: SER[k], values: d.by_time.map(b => b.how[k]) })) })}
          <p class="cap">Hours per ${unit}. <b>Played as is</b>: the player handles the file. <b>Repackaged</b>: Emby only repacks it, almost no work. <b>Converted</b>: Emby converts the video while you watch, real work for the server.</p></div></div>` : ""}
        ${d.resolution.length ? `<div><h3 class="sub">Picture</h3><div class="panel wchart">${colChart({ labels: d.resolution.map(r => r.res), height: 160, every: 1, grouped: true,
            series: [{ name: "In the file", color: SER.File, values: d.resolution.map(r => r.source) }, { name: "Sent to the player", color: SER["On screen"], values: d.resolution.map(r => r.stream) }] })}
          <p class="cap">Plays by picture size: what the file has, and what Emby sent to the player. When the second is lower, Emby shrank the picture.</p></div></div>` : ""}
      </div>
      <h3 class="sub">Players</h3>
      <div class="tablewrap"><table class="ptable"><thead><tr><th>Player</th><th>Plays</th><th>Hours</th><th>Converted by Emby</th><th>Main reason</th></tr></thead><tbody>
        ${d.devices.map(x => `<tr><td>${esc(x.device)}</td><td class="num">${x.plays}</td><td class="num">${hrs(x.hours)}</td>
          <td class="num"><span class="${x.transcode_pct >= 50 ? "meh" : x.transcode_pct ? "" : "good"}">${x.transcode_pct}%</span></td>
          <td class="muted">${x.why ? esc(x.why[0].toUpperCase() + x.why.slice(1)) : "–"}</td></tr>`).join("")}</tbody></table></div>
      <p class="cap">Converted by Emby: the share of each player's watch time that Emby had to convert because the player can't handle the file.</p>
      ${d.reasons.length ? `<h3 class="sub">Why Emby converts</h3>${reasonsTable(d.reasons)}<p class="cap">Tap a row to see those plays in History.</p>` : ""}
    </details>
    <p class="note">${since}</p>`;
}

function historyTable(rows, opts = {}) {
  if (!rows.length) return `<div class="empty"><h3>No plays</h3><p>Nothing matches these filters.</p></div>`;
  const tr = (r, i) => {
    const pct = r.runtime && r.position ? Math.min(100, Math.round(100 * r.position / r.runtime)) : null;
    const quality = r.src_res ? `${esc(r.src_res)}${r.stream_res && r.stream_res !== r.src_res ? ` → ${esc(r.stream_res)}` : ""}` : esc(r.source || "–");
    const det = [
      ["Started", when(r.started)], ["Stopped", when(r.last)], ["Time watched", mins(r.watched)], ["Paused for", r.paused ? mins(r.paused) : r.origin ? "–" : "0 min"],
      ["Player app", [r.client, r.app_version].filter(Boolean).join(" ")], ["Device", r.device], ["IP address", r.ip],
      ["The file", [r.src_res, r.src_codec, r.src_hdr].filter(Boolean).join(" · ")], ["Sent to the player", [r.stream_res, r.stream_codec].filter(Boolean).join(" · ")],
      ["Bitrate", r.bitrate ? `${(r.bitrate / 1000).toFixed(1)} Mbit/s` : ""], ["Audio", r.audio], ["Subtitles", r.subtitles],
      ["How it played", r.method ? `${howWords(r.method).short}: ${howWords(r.method).long}` : ""], ["Why Emby converted it", r.reasons], ["IPTV login", r.login],
      ["Recorded", r.origin === "emby-log" ? "from Emby's activity log (start and stop only)" : "by Dojo"],
    ].filter(([, v]) => v);
    return `<tr class="hrow" data-hrow="${i}">
        <td class="small muted nowrap t-when">${esc(when(r.started))}</td>
        ${opts.noUser ? "" : `<td class="nowrap t-who">${avatar(r.user, r.user_id, "avatar sm")}${toPerson(r.user)}</td>`}
        <td class="t-what"><div class="hwhat">${poster(r.group_id || r.item_id, "poster tiny", r.grp)}<span>${opts.noTitle ? esc(r.title) : toTitle(r.grp, r.via, esc(r.title))}
          <span class="meta small">${r.via === "livetv" ? "live TV" : r.kind === "movie" ? "movie" : r.kind === "episode" ? "episode" : ""}</span></span></div></td>
        <td class="small t-player">${esc(r.client || r.device || "–")}${r.device && r.client && r.device !== r.client ? `<div class="meta">${esc(r.device)}</div>` : ""}</td>
        <td class="small nowrap t-q ${quality === "–" && !r.method ? "nil" : ""}">${quality} ${howTag(r.method)}</td>
        <td class="num nowrap t-w">${mins(r.watched)}</td>
        <td class="prog t-p ${pct == null ? "nil" : ""}">${pct != null ? `<span class="pbar"><span style="width:${pct}%"></span></span><span class="small muted">${pct}%</span>` : `<span class="small muted">${r.via === "livetv" ? "live" : "–"}</span>`}</td></tr>
      <tr class="hdet" data-hdet="${i}" hidden><td colspan="${opts.noUser ? 6 : 7}"><dl>${det.map(([k, v]) => `<div><dt>${k}</dt><dd>${esc(String(v))}</dd></div>`).join("")}</dl></td></tr>`;
  };
  return `<div class="tablewrap"><table class="htable"><thead><tr><th>When</th>${opts.noUser ? "" : "<th>Who</th>"}<th>What</th><th>Player</th><th>Picture · how it played</th><th>Time watched</th><th>Reached</th></tr></thead>
    <tbody>${rows.map(tr).join("")}</tbody></table></div>`;
}

async function watchHistory() {
  const qs = new URLSearchParams({ page: W.page, size: 25, q: W.q, kind: W.kind, user: W.user, why: W.why || "" });
  const d = await api(`/api/watching/history?${qs}`).catch(() => null);
  if (!d) return null;
  if (!d.ok) return `<div class="empty"><h3>No watch history</h3><p>${esc(d.message || "")}</p></div>`;
  const from = d.total ? (W.page - 1) * 25 + 1 : 0, to = Math.min(d.total, W.page * 25);
  return `<div class="hfilters">
      <input type="search" id="hq" placeholder="Search titles, people, players" value="${esc(W.q)}" aria-label="Search">
      <select id="huser" aria-label="Person"><option value="">Everyone</option>${d.users.map(u => `<option ${u === W.user ? "selected" : ""}>${esc(u)}</option>`).join("")}</select>
      <div class="seg sm" role="group" aria-label="Kind">${[["", "All"], ["episode", "Episodes"], ["movie", "Movies"], ["channel", "Live TV"]].map(([k, n]) => `<button data-hkind="${k}" aria-pressed="${W.kind === k}">${n}</button>`).join("")}</div>
      ${W.why ? `<button class="chip" id="hwhy" title="Show all plays">Converted: ${esc(W.why)} <span aria-hidden="true">✕</span></button>` : ""}
    </div>
    ${historyTable(d.rows)}
    <div class="hpager"><span class="muted small">${from}–${to} of ${d.total}</span>
      <span><button class="btn plain" data-hpage="${W.page - 1}" ${W.page <= 1 ? "disabled" : ""}>Newer</button>
      <button class="btn plain" data-hpage="${W.page + 1}" ${to >= d.total ? "disabled" : ""}>Older</button></span></div>
    <p class="note">One row per play: each time someone started something. <b>Reached</b> is how far into it they got. Tap a row for the details: player and IP address, the file and what was sent to the player, audio, subtitles, and why Emby converted it.</p>`;
}

async function watchPerson() {
  const [d, h] = await Promise.all([api(`/api/watching/person?user=${encodeURIComponent(W.person)}&window=${S.win}`).catch(() => null),
    api(`/api/watching/history?${new URLSearchParams({ user: W.person, size: 10 })}`).catch(() => null)]);
  if (!d) return null;
  const back = `<p class="wback"><a href="#stats" class="wlink" data-wview="${esc(W.from || "stats")}">← ${W.from === "history" ? "History" : "Watching"}</a></p>`;
  if (!d.ok) return back + `<div class="empty"><h3>No watch history</h3></div>`;
  const R = d.requests, P = d.totals || {}, all = d.periods.find(p => p.label === "All time");
  const span = { "24h": "the last 24 hours", "7d": "the last 7 days", "30d": "the last 30 days", "90d": "the last 90 days", all: "all time" }[S.win];
  const lc = t => /^(Today|Yesterday)/.test(t) ? t[0].toLowerCase() + t.slice(1) : t;
  return `${back}
    <div class="whead">${avatar(d.user, d.user_id, "avatar xl")}<div><h2>${esc(d.user)}</h2>
      <p class="muted small">${d.first ? `First play ${esc(dayOf(d.first))} · latest ${esc(lc(when(d.last)))}${all && S.win !== "all" ? ` · ${hrs(all.hours)} in all` : ""}` : ""}</p></div></div>

    <h3 class="sub" style="margin-top:4px">In ${span}</h3>
    <div class="now">
      <div><b>${hrs(P.hours || 0)}</b><span>watched</span></div>
      <div><b>${P.plays || 0}</b><span>${P.plays === 1 ? "time" : "times"} something was played${P.titles ? ` · ${plural(P.titles, "different title")}` : ""}</span></div>
      <div><b>${d.finished_pct != null ? d.finished_pct + "%" : "–"}</b><span>of episodes and movies watched to the end</span></div>
      <div><b>${P.plays ? d.transcode_pct + "%" : "–"}</b><span>of the time Emby had to convert the video</span></div>
    </div>

    ${d.recent.length ? `<h2>Recently watched</h2><div class="strip">${d.recent.map(x => `<div class="strip-i">${poster(x.art, "poster", x.grp)}
      <div class="strip-t">${toTitle(x.grp, x.via, esc(x.title))}</div><div class="strip-w muted small">${esc(when(x.when))}</div></div>`).join("")}</div>` : ""}

    <div class="wgrid">
      <div><h2>Most watched <span class="muted small">· ${span}</span></h2><div class="panel" style="padding:12px 16px">${d.top.length ? hbars(d.top, x => x.hours, x => `${poster(x.art, "poster tiny", x.name)}${toTitle(x.name, x.via)}`) : `<p class="muted small">Nothing in this period.</p>`}</div></div>
      <div><h2>When <span class="muted small">· ${span}</span></h2><div class="panel" style="padding:14px 16px">${heatGrid(d.heat)}<p class="cap">The darker a square, the more was watched in that hour of that weekday.</p></div></div>
    </div>

    <div class="wgrid">
      <div><h2>Players <span class="muted small">· all time</span></h2><div class="tablewrap"><table><thead><tr><th>Player</th><th>Plays</th><th>Hours</th><th>Latest</th></tr></thead><tbody>
        ${d.players.map(x => `<tr><td>${esc(x.player)}${x.device && x.device !== x.player ? `<div class="meta small">${esc(x.device)}</div>` : ""}</td><td class="num">${x.plays}</td><td class="num">${hrs(x.hours)}</td><td class="small muted">${esc(when(x.last))}</td></tr>`).join("")}</tbody></table></div></div>
      <div><h2>Watched from <span class="muted small">· all time</span></h2>${d.ips.length ? `<div class="tablewrap"><table><thead><tr><th>IP address</th><th>Plays</th><th>Latest</th></tr></thead><tbody>
        ${d.ips.map(x => `<tr><td><span class="mono">${esc(x.ip)}</span><div class="meta small">${esc(x.player)}</div></td><td class="num">${x.plays}</td><td class="small muted">${esc(when(x.last))}</td></tr>`).join("")}</tbody></table></div>` : `<p class="muted small">None recorded yet.</p>`}</div>
    </div>

    ${R.n ? `<h2>Requests</h2><p class="note" style="margin-top:0">${esc(d.user)} asked for ${plural(R.n, "title")} in Seerr · ${R.ready} ${R.ready === 1 ? "is" : "are"} in the library · ${R.watched} of ${R.ready === 1 ? "it" : "those"} watched${R.ready ? ` (${Math.round(100 * R.watched / R.ready)}%)` : ""}</p>
      <div class="panel"><ul class="list">${R.latest.map(x => `<li><span>${src(x.link, esc(x.title))}</span><span class="meta">${x.watched ? `<span class="good">watched</span>` : x.ready ? "not watched yet" : "not in the library yet"} · ${esc(dayOf(x.when))}</span></li>`).join("")}</ul></div>` : ""}

    <div class="wsec-h"><h2>Latest plays <span class="muted small">· all time</span></h2><a href="#stats" class="wlink small" data-whistory="${esc(d.user)}">All of ${esc(d.user)}'s plays</a></div>
    ${h && h.ok ? historyTable(h.rows, { noUser: true }) : ""}`;
}

async function watchTitle() {
  const [d, h] = await Promise.all([api(`/api/watching/title?${new URLSearchParams({ grp: W.grp, via: W.via || "" })}`).catch(() => null),
    api(`/api/watching/history?${new URLSearchParams({ grp: W.grp, size: 15 })}`).catch(() => null)]);
  if (!d) return null;
  const back = `<p class="wback"><a href="#stats" class="wlink" data-wview="${esc(W.from || "stats")}">← ${W.from === "history" ? "History" : "Watching"}</a></p>`;
  if (!d.ok || !d.totals.plays) return back + `<div class="empty"><h3>No plays of ${esc(W.grp)}</h3></div>`;
  const T = d.totals, kind = d.via === "livetv" ? "Live TV channel" : d.kind === "movie" ? "Movie" : "Series";
  const emby = d.art ? { port: 8096, path: `/web/index.html#!/item?id=${d.art}&serverId=${d.server || ""}`, app: "Emby" } : null;
  return `${back}
    <div class="whead title">${poster(d.art, "poster xl", d.grp)}<div><p class="muted small" style="margin:0">${kind}</p><h2>${src(emby, esc(d.grp))}</h2>
      <p class="muted small">${T.first ? `First watched ${esc(dayOf(T.first))} · last ${esc(when(T.last))}` : ""}</p>
      <div class="wfacts"><span>Played <b>${T.plays}</b> ${T.plays === 1 ? "time" : "times"}</span><span><b>${hrs(T.hours)}</b> watched</span><span>by <b>${T.viewers}</b> ${T.viewers === 1 ? "person" : "people"}</span><span class="muted">all time</span></div></div></div>
    <h2>Who watched</h2>
    <div class="tablewrap"><table><thead><tr><th>Who</th><th>Plays</th><th>Hours</th>${d.via === "livetv" ? "" : `<th title="Plays that reached 90% or more">Watched to the end</th>`}<th>Latest</th></tr></thead><tbody>
      ${d.viewers.map(v => `<tr><td class="nowrap">${avatar(v.user, v.user_id, "avatar sm")}${toPerson(v.user)}</td><td class="num">${v.plays}</td><td class="num">${hrs(v.hours)}</td>${d.via === "livetv" ? "" : `<td class="num">${v.done}</td>`}<td class="small muted">${esc(when(v.last))}</td></tr>`).join("")}</tbody></table></div>
    ${d.episodes.length ? `<h2>Episodes</h2><div class="tablewrap"><table><thead><tr><th>Episode</th><th>Started by</th><th>Finished by</th></tr></thead>
<tbody>
      ${d.episodes.map(e => `<tr><td>${esc(e.title.replace(d.grp + " ", ""))}</td><td class="small">${e.viewers.map(esc).join(", ")}</td><td class="small">${e.done.length ? e.done.map(esc).join(", ") : `<span class="muted">–</span>`}</td></tr>`).join("")}</tbody></table></div>` : ""}
    <h2>Plays</h2>${h && h.ok ? historyTable(h.rows, { noTitle: true }) : ""}`;
}

// clicks inside Watching (called after each render)
function bindWatching(el, load) {
  bindCharts(el);
  el.querySelectorAll("[data-wview]").forEach(b => b.onclick = e => { e.preventDefault(); W.view = b.dataset.wview; window.scrollTo(0, 0); load(); });
  el.querySelectorAll("[data-wmetric]").forEach(b => b.onclick = () => { W.metric = b.dataset.wmetric; load(); });
  el.querySelectorAll("[data-wtop]").forEach(b => b.onclick = () => { W.top = b.dataset.wtop; load(); });
  el.querySelectorAll("[data-wrank]").forEach(b => b.onclick = () => { W.rank = b.dataset.wrank; load(); });
  const pb = $("details.pb", el); if (pb) pb.ontoggle = () => setPref("stats.playback", pb.open ? "open" : "closed");
  el.querySelectorAll("[data-wperson]").forEach(b => b.onclick = e => { e.preventDefault(); W.from = W.view === "person" || W.view === "title" ? W.from : W.view; W.view = "person"; W.person = b.dataset.wperson; window.scrollTo(0, 0); load(); });
  el.querySelectorAll("[data-wtitle]").forEach(b => b.onclick = e => { e.preventDefault(); W.from = W.view === "person" || W.view === "title" ? W.from : W.view; W.view = "title"; W.grp = b.dataset.wtitle; W.via = b.dataset.wvia; window.scrollTo(0, 0); load(); });
  el.querySelectorAll("[data-whistory]").forEach(b => b.onclick = e => { e.preventDefault(); W.view = "history"; W.user = b.dataset.whistory; W.page = 1; load(); });
  el.querySelectorAll("[data-hrow]").forEach(r => r.onclick = e => { if (e.target.closest("a")) return; const d = $(`[data-hdet="${r.dataset.hrow}"]`, r.closest("tbody")); d.hidden = !d.hidden; r.classList.toggle("open", !d.hidden); });
  el.querySelectorAll("[data-hkind]").forEach(b => b.onclick = () => { W.kind = b.dataset.hkind; W.page = 1; load(); });
  el.querySelectorAll("[data-hpage]").forEach(b => b.onclick = () => { W.page = +b.dataset.hpage; load(); });
  const u = $("#huser", el); if (u) u.onchange = () => { W.user = u.value; W.page = 1; load(); };
  const hw = $("#hwhy", el); if (hw) hw.onclick = () => { W.why = ""; W.page = 1; load(); };
  el.querySelectorAll("[data-why]").forEach(r => r.onclick = r.onkeydown = e => { if (e.type === "keydown" && e.key !== "Enter") return;
    S.stab = "history"; W.view = "history"; W.why = r.dataset.why; W.user = ""; W.q = ""; W.kind = ""; W.page = 1; window.scrollTo(0, 0); pageStats(); });
  const q = $("#hq", el); if (q) { let t; q.oninput = () => { clearTimeout(t); t = setTimeout(() => { W.q = q.value; W.page = 1; load().then(() => { const n = $("#hq"); if (n) { n.focus(); n.setSelectionRange(n.value.length, n.value.length); } }); }, 350); }; }
}

// The library in a few lines: what it holds, does it play, what's missing, language, picture, upgrades
// AV1 is only a problem for players that can't decode it (Apple TV, Nvidia Shield, TVs before about
// 2020), so the note goes by what the household's own players did with it in the last 30 days.
const players = o => Object.keys(o || {}).sort((a, b) => o[b] - o[a]);
const av1Converted = Q => Q.av1 && players((Q.av1_players || {}).converted).length;
function pictureNote(Q, t) {
  const notes = [];
  if (Q.av1) {
    const conv = players((Q.av1_players || {}).converted), direct = players((Q.av1_players || {}).direct);
    const names = l => l.length > 3 ? `${l.slice(0, 3).join(", ")} and ${l.length - 3} more` : l.join(" and ").replace(/ and (?=.* and )/g, ", ");
    notes.push(conv.length
      ? `<span class="meh">${plural(Q.av1, "file")} in AV1</span>: Emby had to convert AV1 ${plural(conv.reduce((n, x) => n + Q.av1_players.converted[x], 0), "time")} in the last 30 days because your ${esc(names(conv))} ${conv.length === 1 ? "player doesn't" : "players don't"} decode it. That's heavy on the CPU unless the GPU decodes AV1 (Intel 11th gen or newer). New grabs avoid AV1; <i>Look for better</i> replaces these: ${t(Q.av1_titles)}.`
      : direct.length
        ? `${plural(Q.av1, "file")} in AV1 — ${esc(names(direct))} ${direct.length === 1 ? "plays" : "play"} AV1 directly, so that's fine.`
        : `${plural(Q.av1, "file")} in AV1 — fine on most TVs from 2020 on, but Apple TV, Nvidia Shield and older TVs make Emby convert it. None of your players has played one in the last 30 days.`);
  }
  if (Q.dv_only) notes.push(`<span class="meh">${plural(Q.dv_only, "file")} in Dolby Vision without HDR</span>: only Dolby Vision screens show the right colours; everywhere else Emby converts it and it can look washed out: ${t(Q.dv_titles)}.`);
  return notes.length ? `<br>${notes.join("<br>")}` : "";
}
function libraryPanel(L, span) {
  const t = list => list.map(x => `${src(x.link, esc(x.title))}${x.n > 1 ? ` <span class="meta">(${x.unit ? plural(x.n, x.unit) : x.n})</span>` : ""}`).join(" · ");
  const row = (label, value, detail, action = "") => `<div class="lrow"><div class="llabel">${label}</div>
      <div><div class="lvalue">${value}</div>${detail ? `<div class="ldetail">${detail}</div>` : ""}</div><div class="actions">${action}</div></div>`;
  const P = L.plays, M = L.missing, G = L.language, Q = L.picture;
  const oldNote = P && P.unused ? ` It also lists ${plural(P.unused, "older release")} with problems that nothing plays from any more — Sonarr and Radarr already replaced ${P.unused === 1 ? "it" : "them"}.` : "";
  const total = Q["2160p"] + Q["1080p"] + Q["720p"] + Q.lower || 1;
  const pctOf = n => Math.round(100 * n / total);
  const seg = (k, cls) => Q[k] ? `<span class="${cls}" style="width:${100 * Q[k] / total}%" title="${k}: ${Q[k]}"></span>` : "";
  const parts = [L.series && plural(L.series, "series", "series"), L.episodes && plural(L.episodes, "episode"), L.movies && plural(L.movies, "movie")].filter(Boolean);
  return `<h2 class="first">${parts.join(", ")}</h2><div class="panel lib">
    ${row("Plays well?", !P ? `<span class="muted">AIOStreams didn't answer</span>`
        : P.degraded || P.dead ? [P.degraded && `<span class="meh">${plural(P.degraded, "file")} with missing parts</span>`, P.dead && `<span class="bad">${P.dead} gone from usenet</span>`].filter(Boolean).join(" · ")
        : `<span class="good">All ${P.files} files are complete on usenet</span>`,
      P && (P.degraded || P.dead)
        ? `${P.items.map(x => `<span class="${x.dead ? "bad" : "meh"}">${src(x.link, esc(x.title))}</span>`).join(" · ")}${P.more ? ` <span class="meta">and ${P.more} more</span>` : ""}
           <br>${[P.degraded && "Missing parts can make playback stutter or stop; Replace swaps them for another release.", P.dead && "Gone ones don't play; AIOStreams has Sonarr/Radarr replace them by itself, Replace does it now."].filter(Boolean).join(" ")} Checked every night by ${at("AIOStreams", "/dashboard/usenet/library", "AIOStreams")}.${oldNote}`
        : `Your files stream from usenet; ${at("AIOStreams", "/dashboard/usenet/library", "AIOStreams")} checks every night that none of their parts went missing.${oldNote}`,
      P && (P.degraded || P.dead) ? `<button class="btn" data-libs="sonarr/replace-broken radarr/replace-broken" data-confirm="replace">Replace ${P.degraded + P.dead}</button>` : "")}
    ${row("Not found yet", M.episodes || M.movies ? [M.episodes && plural(M.episodes, "episode"), M.movies && plural(M.movies, "movie")].filter(Boolean).join(" · ") : `<span class="good">Nothing waiting</span>`,
      M.episodes || M.movies ? `${t(M.titles)}<br>Already out and wanted, but no release found yet. Sonarr and Radarr keep looking · ${[M.episodes && at("Sonarr", "/wanted/missing", "Sonarr"), M.movies && at("Radarr", "/wanted/missing", "Radarr")].filter(Boolean).join(" · ")}` : "Every aired episode and released movie you follow has a file.",
      M.episodes || M.movies ? `<button class="btn" data-libs="sonarr/search-missing radarr/search-missing">Search now</button>` : "")}
    ${G ? row("Language", `${G.pct}% of files have ${esc(G.name)} audio`, G.other ? `${plural(G.other, "file")} without ${esc(G.name)} audio: ${t(G.titles)}` : "",
      G.other ? `<button class="btn" data-libs="sonarr/upgrade-language radarr/upgrade-language">Find ${esc(G.name)}</button>` : "") : ""}
    ${row("Picture", `${pctOf(Q["2160p"])}% in 4K <span class="muted">·</span> ${pctOf(Q.hdr)}% with HDR or Dolby Vision`,
      `${[Q["2160p"] && `${Q["2160p"]} in 4K`, Q["1080p"] && `${Q["1080p"]} in 1080p`, (Q["720p"] + Q.lower) && `${Q["720p"] + Q.lower} below 1080p`].filter(Boolean).join(" · ")}${pictureNote(Q, t)}`,
      Q.dv_only || av1Converted(Q) ? `<button class="btn" data-libs="sonarr/upgrade-hard radarr/upgrade-hard">Look for better</button>` : "")}
    ${row("Upgrades", `${L.upgrades.done} ${L.upgrades.done === 1 ? "file" : "files"} swapped for a better release <span class="muted">in the last ${span}</span>`,
      L.upgrades.waiting ? `${L.upgrades.waiting} could still get better (your language in 4K). Sonarr and Radarr swap them by themselves when such a release appears · ${at("Sonarr", "/wanted/cutoffunmet", "Sonarr")} · ${at("Radarr", "/wanted/cutoffunmet", "Radarr")}` : "")}

  </div>`;
}

async function timeline() {
  const d = await api("/api/activity").catch(() => null);
  if (!d) return null;
  const names = { request: "Requested", grab: "Release picked", import: "In library", failed: "Failed", deleted: "Removed", play: "Watched" };
  const day = t => { const w = when(t); return /^(Today|Yesterday)/.test(w) ? w.split(",")[0]
    : new Date(t * 1000).toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" }); };
  const f = S.tlf || "all";
  const chips = `<p class="lead-s">Everything that happened, newest first: requests in Seerr, releases Sonarr and Radarr picked, what landed in the library, and what people watched.</p>
    <div class="seg" role="group" aria-label="Show" style="margin-bottom:14px">${[["all", "Everything"], ["play", "Watched"], ["library", "Requests and downloads"]]
    .map(([k, n]) => `<button data-tlf="${k}" aria-pressed="${f === k}">${n}</button>`).join("")}</div>`;
  const shown = d.events.filter(e => f === "all" || (f === "play") === (e.kind === "play"));
  let last = "", rows = "";
  for (const e of shown) {
    const dd = day(e.t);
    if (dd !== last) { rows += `<li class="day">${dd}</li>`; last = dd; }
    rows += `<li class="ev"><span class="time">${new Date(e.t * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</span>
      <span class="kind k-${e.kind}">${names[e.kind]}</span>
      <span class="body"><span>${src(e.link, esc(e.title))}</span>${e.detail ? `<div class="detail">${esc(e.detail)}</div>` : ""}</span></li>`;
  }
  return chips + (rows ? `<ul class="timeline">${rows}</ul>`
    : `<div class="empty"><h3>Nothing here yet</h3><p>Requests, downloads and what everyone watched show up here as they happen.</p></div>`);
}

// ───────────────────────── settings (also the setup form)
// pick lists: usenet providers (usenet.rexum.space, as used by AIOStreams) and Prowlarr's indexers
const CAT = { providers: [], indexers: [] };
async function loadCatalog() { if (!CAT.loaded) { Object.assign(CAT, await api("/api/catalog").catch(() => ({})), { loaded: true }); } }
const hostRoot = h => (h || "").toLowerCase().split(".").slice(-2).join(".");
function providerFor(host) {
  host = (host || "").toLowerCase();
  if (!host) return null;
  return CAT.providers.find(x => x.host === host) || CAT.providers.find(x => hostRoot(x.host) === hostRoot(host));
}
function providerPick(p) {
  const cur = providerFor(p.host);
  const groups = {};
  CAT.providers.forEach((x, n) => (groups[x.backbone || "Other"] ||= []).push([x, n]));
  return `<label class="field"><span>Provider</span><select data-pick="provider">
    <option value="">Choose your provider…</option>
    ${Object.keys(groups).sort().map(g => `<optgroup label="${esc(g)} backbone">${groups[g].map(([x, n]) =>
      `<option value="${n}" ${cur === x ? "selected" : ""}>${esc(x.name)}${x.block ? " (block account)" : ""}</option>`).join("")}</optgroup>`).join("")}
    <option value="other" ${p.host && !cur ? "selected" : ""}>Another server, typed in</option></select></label>
    <p class="small muted pickinfo" style="margin:-6px 0 12px">${cur ? providerInfo(cur) : ""}</p>`;
}
const providerInfo = x => `Runs on the ${esc(x.backbone || "unknown")} backbone (the network behind it)${x.block ? " · pay per GB, good as a backup" : ""} · set Connections to the number your plan allows`;
function indexerPick(x) {
  const cur = CAT.indexers.find(c => c.name === x.preset || (x.url && c.url === x.url));
  return `<label class="field"><span>Indexer</span><select data-pick="indexer">
    <option value="">Choose your indexer…</option>
    ${CAT.indexers.map((c, n) => `<option value="${n}" ${cur === c ? "selected" : ""}>${esc(c.name)}</option>`).join("")}
    <option value="other" ${x.url && !cur ? "selected" : ""}>Another Newznab indexer</option></select></label>
    <input type="hidden" name="preset" value="${esc(cur ? cur.name : "")}"><input type="hidden" name="apiPath" value="${esc((cur && cur.apiPath) || x.apiPath || "/api")}">`;
}
function backboneNote(root) {
  const seen = {};
  root.querySelectorAll("[data-provider]").forEach(e => {
    const h = $("[name=host]", e).value.trim(); if (!h) return;
    const x = providerFor(h); if (!x || !x.backbone) return;
    (seen[x.backbone] ||= []).push(x.name);
  });
  const dup = Object.entries(seen).find(([, names]) => names.length > 1);
  const el = $("#backbonenote", root);
  if (el) el.innerHTML = dup ? `<span class="meh">${dup[1].map(esc).join(" and ")} share the ${esc(dup[0])} backbone,</span> so one rarely fills the other's gaps. Pick a backup on another backbone.` : "";
}
const SAVED = "Saved · type to change";
// each provider/indexer folds to one line (name, server, connections); new ones start open
const foldHead = () => `<summary><div><h3 data-ename></h3><div class="sum" data-esum></div></div>
    <button type="button" class="btn plain danger small" data-remove aria-label="Remove"><span class="rm-t">Remove</span><svg class="rm-i" aria-hidden="true"><use href="#i-trash"/></svg></button><svg class="chev" aria-hidden="true"><use href="#i-chev"/></svg></summary>`;
function providerEntry(p = {}, i = 0, open = true) {
  return `<details class="entry fe" data-provider ${open ? "open" : ""}>${foldHead()}<div class="fe-body">
    ${providerPick(p)}
    <div class="row"><label class="field"><span>Server</span><input type="text" name="host" value="${esc(p.host || "")}" placeholder="news.provider.example" required></label>
      <label class="field"><span>Port</span><input type="number" name="port" value="${esc(p.port || 563)}"></label>
      <label class="field"><span>Connections</span><input type="number" name="maxConnections" value="${esc(p.maxConnections || 20)}"></label></div>
    <div class="row"><label class="field"><span>Username</span><input type="text" name="username" value="${esc(p.username || "")}" autocomplete="off"></label>
      <label class="field"><span>Password</span><input type="password" name="password" placeholder="${p.has_password ? SAVED : ""}" autocomplete="new-password"></label></div>
    <label class="check"><input type="checkbox" name="tls" ${p.tls === false ? "" : "checked"}><span>SSL/TLS</span></label>
    <label class="check"><input type="checkbox" name="isBackup" ${p.isBackup ? "checked" : ""}><span>Backup only <span class="muted small">· only asked for pieces the others are missing</span></span></label>
    <button type="button" class="btn" data-test="usenet">Test login</button><p class="result"></p></div></details>`;
}
function indexerEntry(x = {}, open = true) {
  return `<details class="entry fe" data-indexer ${open ? "open" : ""}>${foldHead()}<div class="fe-body">
    ${indexerPick(x)}
    <div class="row"><label class="field"><span>Name</span><input type="text" name="name" value="${esc(x.name || "")}" placeholder="My Indexer"></label>
      <label class="field"><span>URL</span><input type="url" name="url" value="${esc(x.url || "")}" placeholder="https://indexer.example.com"></label></div>
    <label class="field"><span>API key</span><input type="password" name="apikey" placeholder="${x.has_key ? SAVED : ""}" autocomplete="new-password"></label>
    <button type="button" class="btn" data-test="indexer">Test API key</button><p class="result"></p></div></details>`;
}
// a provider's role: backup, or main — together with the other main ones, or its place in the order
function roleBadge(box) {
  const form = box.closest("form") || document;
  if ($("[name=isBackup]", box).checked) { box.dataset.role = "backup"; return `<span class="role role-backup">Backup only</span>`; }
  box.dataset.role = "main";
  const mains = [...form.querySelectorAll("[data-provider]")].filter(e => !$("[name=isBackup]", e).checked);
  const sw = $("[name=usenet_balanced]", form);
  if (mains.length < 2) return `<span class="role role-main">Main</span>`;
  if (!sw || sw.checked) return `<span class="role role-main">Main · together</span>`;
  const n = mains.indexOf(box) + 1;
  return `<span class="role role-main">Main · ${n === 1 ? "first" : n === 2 ? "second" : n + "th"}</span>`;
}
// the folded line of a provider/indexer, kept current while editing
function entrySum(box) {
  const v = n => ($(`[name=${n}]`, box) || {}).value || "";
  if (box.matches("[data-provider]")) {
    const host = v("host").trim(), x = providerFor(host), backup = $("[name=isBackup]", box).checked;
    $("[data-ename]", box).innerHTML = `${esc((x && x.name) || host || "New provider")} ${roleBadge(box)}`;
    $("[data-esum]", box).textContent = host ? `${host} · ${v("maxConnections") || "?"} connections` : "Not filled in yet";
  } else {
    let host = ""; try { host = new URL(v("url")).host; } catch (_) {}
    $("[data-ename]", box).textContent = v("name").trim() || host || "New indexer";
    $("[data-esum]", box).textContent = host || "Not filled in yet";
  }
}
// time zone as a list grouped by region, from the browser's own list of IANA zones
function tzField(current) {
  let zones = [];
  try { zones = Intl.supportedValuesOf("timeZone"); } catch (_) {}
  const browser = (() => { try { return Intl.DateTimeFormat().resolvedOptions().timeZone; } catch (_) { return ""; } })();
  const pick = current || browser || "UTC";
  if (!zones.length) zones = [pick];
  if (!zones.includes(pick)) zones.push(pick);
  if (!zones.includes("UTC")) zones.push("UTC");
  const groups = {};
  for (const z of zones.sort()) (groups[z.includes("/") ? z.split("/")[0] : "Other"] ||= []).push(z);
  const opt = z => `<option value="${esc(z)}" ${z === pick ? "selected" : ""}>${esc(z.replace(/_/g, " ").replace(/\//g, " / "))}</option>`;
  return `<label class="field"><span>Time zone</span><select name="tz">${Object.entries(groups).map(([g, list]) =>
    `<optgroup label="${esc(g)}">${list.map(opt).join("")}</optgroup>`).join("")}</select></label>
    ${browser && browser !== pick ? `<p class="small muted" style="margin-top:-6px">This browser uses ${esc(browser.replace(/_/g, " "))}.</p>` : ""}`;
}

// Each section: a title, one line, more behind ⓘ, and the fields. Settings folds them, setup shows them.
function settingsForm(s) {
  return {
    login: { title: "Your login", lead: "One login for every app and for Dojo.",
      body: `<div class="row"><label class="field"><span>Username</span><input type="text" name="admin_user" value="${esc(s.admin_user || "admin")}" autocomplete="username"></label>
      <label class="field"><span>Password</span><input type="password" name="admin_password" autocomplete="new-password" minlength="8" placeholder="8+ characters, no comma"></label></div>
      ${tzField(s.tz)}` },
    tz: { title: "Time zone", lead: "For schedules, logs and the nightly backup.", body: tzField(s.tz) },
    usenet: { title: "Usenet providers", lead: "The paid services your movies and shows are streamed from.",
      more: "A second provider on a different backbone fills in the pieces (articles) the first one is missing. Mark a pay-per-GB block account as backup, so it's only asked for those.",
      body: `<label class="check" data-balance><input type="checkbox" name="usenet_balanced" ${s.usenet_balanced !== false ? "checked" : ""}><span>Use the main providers together <span class="muted small">· load-balanced</span></span></label>
      <p class="small muted" data-balance style="margin:-8px 0 14px">${"On: AIOStreams spreads downloads across them by speed and free connections. Off: the first one does the work; the next one steps in only when the first is missing a piece or fails."}</p>
      <div id="providers">${(s.providers.length ? s.providers : [{}]).map((p, i) => providerEntry(p, i, !p.host)).join("")}</div>
      <p class="small" id="backbonenote"></p>
      <div class="adder"><button type="button" class="btn" id="addprov">Add a provider</button></div>` },
    indexers: { title: "Indexers", lead: "Search sites that list what's on usenet. Sonarr and Radarr find releases through them.",
      more: "They go into Prowlarr, which Sonarr and Radarr search. Removing one here doesn't remove it from Prowlarr.",
      body: `<div id="indexers">${s.indexers.map(x => indexerEntry(x, !x.url)).join("")}</div><div class="adder"><button type="button" class="btn" id="addidx">Add an indexer</button></div>` },
    language: { title: "Audio language", lead: "Releases with this audio language are preferred, even over a sharper picture.",
      more: "For example, German in 1080p beats English in 4K (2160p). Between two German releases, the 4K one wins.",
      body: `<label class="field"><span>Language</span><select name="language"><option value="none">No preference, the best picture wins</option>
        ${s.languages.map(l => `<option ${l === s.language ? "selected" : ""}>${l}</option>`).join("")}</select></label>
      <label class="check" data-lang><input type="checkbox" name="require_language" ${s.require_language ? "checked" : ""}><span>Only grab releases in this language</span></label>
      <label class="field" data-wait><span>Minutes to wait for this language before taking another</span><input type="number" min="0" name="wait_minutes" value="${s.wait_minutes}"></label>` },
    subtitles: { title: "Subtitles", lead: "Bazarr fetches subtitles by itself from Podnapisi and Gestdown. An account adds more.",
      more: "An OpenSubtitles.com account adds the biggest catalogue, about 20 downloads a day for free.",
      body: `<div class="row"><label class="field"><span>OpenSubtitles.com username</span><input type="text" name="opensubtitles_user" value="${esc(s.opensubtitles_user)}" autocomplete="off" placeholder="optional"></label>
      <label class="field"><span>Password</span><input type="password" name="opensubtitles_pass" placeholder="${s.has_opensubtitles_pass ? SAVED : ""}" autocomplete="new-password"></label></div>` },
    livetv: { title: "Live TV", lead: "Watch the channels of an IPTV subscription in Emby, with a programme guide.",
      more: "Dispatcharr turns your IPTV subscription into channels; you pick which ones in Dispatcharr. Watching Live TV in Emby needs Emby Premiere.",
      body: `<label class="check"><input type="checkbox" name="iptv" ${s.iptv ? "checked" : ""}><span>Use Live TV</span></label>
      <div id="tvfields" class="${s.iptv ? "" : "hidden"}">
        <label class="field"><span>Provider type</span><select name="iptv_type">
          <option value="xtream" ${s.iptv_type === "xtream" ? "selected" : ""}>Xtream Codes login</option>
          <option value="m3u" ${s.iptv_type === "m3u" ? "selected" : ""}>M3U playlist link</option>
          <option value="" ${s.iptv && !s.iptv_type ? "selected" : ""}>I'll add it in Dispatcharr myself</option></select></label>
        <label class="field" data-tv="xtream m3u"><span>Server or playlist URL</span><input type="url" name="iptv_url" value="${esc(s.iptv_url)}"></label>
        <div class="row" data-tv="xtream"><label class="field"><span>Username</span><input type="text" name="iptv_user" value="${esc(s.iptv_user)}" autocomplete="off"></label>
          <label class="field"><span>Password</span><input type="password" name="iptv_pass" placeholder="${s.has_iptv_pass ? SAVED : ""}" autocomplete="new-password"></label></div>
        <label class="field" data-tv="m3u"><span>Guide (XMLTV) URL</span><input type="url" name="iptv_epg_url" value="${esc(s.iptv_epg_url)}" placeholder="optional"></label>
        <label class="field" data-tv="xtream m3u"><span>Streams your plan allows at once</span><input type="number" min="1" name="iptv_max_streams" value="${s.iptv_max_streams}"></label>
        <div data-tv="xtream m3u"><button type="button" class="btn" data-test="iptv">Test provider</button><p class="result"></p></div>
        ${s.setup ? "" : `<div class="entry" style="margin-top:6px">
          <div class="entry-head"><h3>Live TV in Dojo</h3>${s.has_dispatcharr_key ? `<span class="good small">Connected</span>` : ""}</div>
          <p class="lead-s">${s.has_dispatcharr_key ? "Dojo reads what's playing through Dispatcharr. Sign in again only to reconnect." : "Sign in once with your Dispatcharr login, so Dojo can show what's playing there."}</p>
          ${s.has_dispatcharr_key ? `<p style="margin:0 0 14px"><button type="button" class="btn quiet" data-dshow>Sign in again</button></p>` : ""}
          <div data-dform class="${s.has_dispatcharr_key ? "hidden" : ""}">
            <div class="row"><label class="field"><span>Dispatcharr username</span><input type="text" data-d="user" autocomplete="off"></label>
              <label class="field"><span>Password</span><input type="password" data-d="pass" autocomplete="new-password"></label></div>
            <button type="button" class="btn" data-dconnect>Connect</button><p class="result"></p></div></div>`}
      </div>` },
    notify: { title: "Notifications", lead: s.setup ? "A Discord message when something is downloaded, arrives in the library, or breaks." : "Get told when something happens: on this phone or computer, and in Discord.",
      body: `${s.setup ? "" : `<div class="entry" id="pushbox"><div class="entry-head"><h3>On this device</h3><span class="small" data-pstate></span></div>
        <div data-pbody><p class="lead-s muted">Looking…</p></div></div>`}
      <label class="field"><span>Discord webhook</span><input type="url" name="discord_webhook" value="${esc(s.discord_webhook)}" placeholder="https://discord.com/api/webhooks/…"></label>` },
    remote: { title: "Away from home", lead: "Use Emby, Seerr and AIOStreams outside your home, over secure (HTTPS) addresses on your own domain.",
      more: "They become emby., request. and stream. under your domain. Point those names at your home and forward ports 80 and 443 to this machine. Dojo stays home-only.",
      body: `<div class="row"><label class="field"><span>Domain</span><input type="text" name="domain" value="${esc(s.domain)}" placeholder="example.com"></label>
      <label class="field"><span>E-mail for certificate notices</span><input type="email" name="acme_email" value="${esc(s.acme_email)}"></label></div>
      <label class="check"><input type="checkbox" name="dojo_https" ${s.dojo_https ? "checked" : ""}><span>Dojo too, at dojo.<i>domain</i> — home network only</span></label>
      <p class="small muted" style="margin:-6px 0 14px">An HTTPS address for Dojo, so phones can install it as a full app. It answers only devices on your home network; from the internet it refuses. It needs the same public DNS record as the others (for its certificate) and, at home, a rewrite of the name to this machine.</p>
      <button type="button" class="btn" data-test="domain">Check DNS</button><p class="result"></p>` },
    updates: { title: "Security updates", lead: "The server's operating system (Debian) installs security fixes by itself every night.",
      more: "Only security fixes, from Debian. Docker is left out: it updates together with ninjarr, because updating it restarts every container. Some fixes (the Linux kernel) only take effect after a restart.",
      body: `<label class="check"><input type="checkbox" name="auto_reboot" ${s.auto_reboot ? "checked" : ""}><span>Restart the server at about 04:45 when an update needs it</span></label>
      <p class="small muted" style="margin:-6px 0 14px">Off: Home tells you when a restart is due, with a Restart now button. Streams stop for about a minute during a restart.</p>` },
    backup: { title: "Backups", lead: "A copy of every app's settings and data, nightly at about 04:30, on this machine's disk.",
      more: "Your movies and shows aren't in it: they stream from usenet. Download a backup now and then from System, so a copy lives somewhere else.",
      body: `<label class="check"><input type="checkbox" name="backup_on" ${s.backup_schedule !== "off" ? "checked" : ""}><span>Back up every night</span></label>
      <label class="field" style="max-width:260px"><span>How many backups to keep</span><input type="number" min="1" max="60" name="backup_keep" value="${s.backup_keep}"></label>` },
  };
}
const leadP = x => x.lead ? `<p class="lead-s">${x.lead}${x.more ? info(x.more) : ""}</p>` : "";
const plainSection = x => `<section class="section"><h2>${x.title}</h2>${leadP(x)}${x.body}</section>`;

function bindForm(root) {
  const changed = () => root.dispatchEvent(new Event("input", { bubbles: true }));
  const tvSync = () => {
    const on = $("[name=iptv]", root).checked, t = $("[name=iptv_type]", root).value;
    $("#tvfields", root).classList.toggle("hidden", !on);
    root.querySelectorAll("[data-tv]").forEach(x => x.classList.toggle("hidden", !x.dataset.tv.split(" ").includes(t)));
  };
  if ($("[name=iptv]", root)) { $("[name=iptv]", root).addEventListener("change", tvSync); $("[name=iptv_type]", root).addEventListener("change", tvSync); tvSync(); }
  const langSync = () => {
    const none = $("[name=language]", root).value === "none", only = $("[name=require_language]", root).checked;
    $("[data-lang]", root).classList.toggle("hidden", none);
    $("[data-wait]", root).classList.toggle("hidden", none || only);
  };
  if ($("[name=language]", root)) { $("[name=language]", root).addEventListener("change", langSync); $("[name=require_language]", root).addEventListener("change", langSync); langSync(); }
  const addp = $("#addprov", root); if (addp) addp.onclick = () => { $("#providers", root).insertAdjacentHTML("beforeend", providerEntry({}, 1)); entrySum($("#providers", root).lastElementChild); changed(); };
  const addi = $("#addidx", root); if (addi) addi.onclick = () => { $("#indexers", root).insertAdjacentHTML("beforeend", indexerEntry({})); entrySum($("#indexers", root).lastElementChild); changed(); };
  root.addEventListener("change", e => {
    const sel = e.target.closest("[data-pick]");
    if (!sel) return;
    const box = sel.closest(".entry"), set = (n, v) => { const x = $(`[name=${n}]`, box); if (x) x.type === "checkbox" ? (x.checked = v) : (x.value = v); };
    if (sel.dataset.pick === "provider") {
      const x = CAT.providers[+sel.value];
      $(".pickinfo", box).innerHTML = x ? providerInfo(x) : "";
      if (x) { set("host", x.host); set("port", x.port); set("tls", x.tls); set("maxConnections", x.connections);
        if (x.block && box.previousElementSibling) set("isBackup", true); $("[name=username]", box).focus(); }
      else if (sel.value === "other") { set("host", ""); $("[name=host]", box).focus(); }
      backboneNote(root);
    } else {
      const x = CAT.indexers[+sel.value];
      if (x) { set("name", x.name); set("url", x.url); set("preset", x.name); set("apiPath", x.apiPath); $("[name=apikey]", box).focus(); }
      else { set("preset", ""); set("apiPath", "/api"); if (sel.value === "other") $("[name=url]", box).focus(); }
    }
    changed();
  });
  const balanceSync = () => {
    const main = [...root.querySelectorAll("[data-provider]")].filter(e => !$("[name=isBackup]", e).checked && $("[name=host]", e).value.trim()).length;
    root.querySelectorAll("[data-balance]").forEach(x => x.classList.toggle("hidden", main < 2));
    root.querySelectorAll("[data-provider]").forEach(entrySum);   // roles depend on all of them
  };
  const sumOf = e => { const box = e.target.closest && e.target.closest("[data-provider], [data-indexer]"); if (box) entrySum(box); };
  root.addEventListener("input", e => { if (e.target.name === "host") backboneNote(root); balanceSync(); sumOf(e); });
  root.addEventListener("change", e => { balanceSync(); sumOf(e); });
  root.querySelectorAll("[data-provider], [data-indexer]").forEach(entrySum);
  backboneNote(root); balanceSync();
  root.addEventListener("click", async e => {
    const inf = e.target.closest("[data-info]");
    if (inf) { e.preventDefault(); const h = inf.parentElement.nextElementSibling; h.classList.toggle("hidden"); inf.setAttribute("aria-expanded", !h.classList.contains("hidden")); return; }
    const ds = e.target.closest("[data-dshow]");
    if (ds) { ds.parentElement.remove(); $("[data-dform]", root).classList.remove("hidden"); return; }
    const dc = e.target.closest("[data-dconnect]");
    if (dc) {
      const box = dc.closest(".entry"), out = dc.nextElementSibling;
      dc.disabled = true; out.className = "result"; out.textContent = "Connecting…";
      const r = await api("/api/dispatcharr/connect", { method: "POST", body: { username: $("[data-d=user]", box).value, password: $("[data-d=pass]", box).value } }).catch(() => ({ ok: false }));
      dc.disabled = false; out.className = `result ${r.ok ? "ok" : "fail"}`; out.textContent = r.message || (r.ok ? "Connected" : "Didn't work");
      if (r.ok) $("[data-d=pass]", box).value = "";
      return;
    }
    const rm = e.target.closest("[data-remove]");
    if (rm) { e.preventDefault(); rm.closest(".entry").remove(); backboneNote(root); balanceSync(); changed(); return; }
    const t = e.target.closest("[data-test]");
    if (!t) return;
    const box = t.closest(".entry") || t.closest(".fold-body") || t.closest(".section") || t.parentElement;
    const out = t.nextElementSibling;
    const v = n => { const x = $(`[name=${n}]`, box); return x ? (x.type === "checkbox" ? x.checked : x.value) : ""; };
    let body;
    if (t.dataset.test === "usenet") body = { host: v("host"), port: v("port"), tls: v("tls"), username: v("username"), password: v("password") };
    if (t.dataset.test === "indexer") body = { url: v("url"), apikey: v("apikey"), apiPath: v("apiPath") };
    if (t.dataset.test === "iptv") body = { type: v("iptv_type"), url: v("iptv_url"), user: v("iptv_user"), password: v("iptv_pass") };
    if (t.dataset.test === "domain") body = { domain: v("domain"), dojo_https: v("dojo_https") };
    t.disabled = true; out.className = "result"; out.textContent = "Testing…";
    const r = await api(`/api/test/${t.dataset.test}`, { method: "POST", body }).catch(() => ({ ok: false }));
    t.disabled = false; out.className = `result ${r.ok ? "ok" : "fail"}`; out.textContent = r.message || (r.ok ? "Works" : "Didn't work");
    if (t.dataset.test === "iptv" && r.ok && r.max_connections) { $("[name=iptv_max_streams]", root).value = r.max_connections; changed(); }
  });
}
function collect(root) {
  const v = n => { const x = $(`[name=${n}]`, root); return x ? (x.type === "checkbox" ? x.checked : x.value) : undefined; };
  const list = (sel, names) => [...root.querySelectorAll(sel)].map(e => Object.fromEntries(names.map(n => {
    const x = $(`[name=${n}]`, e); return [n, x.type === "checkbox" ? x.checked : x.value]; })));
  const on = v("backup_on");
  return {
    admin_user: v("admin_user"), admin_password: v("admin_password"), tz: v("tz"),
    providers: list("[data-provider]", ["host", "port", "maxConnections", "username", "password", "tls", "isBackup"]),
    usenet_balanced: v("usenet_balanced"),
    indexers: list("[data-indexer]", ["name", "url", "apikey", "preset", "apiPath"]),
    language: v("language"), require_language: v("require_language"), wait_minutes: v("wait_minutes"),
    opensubtitles_user: v("opensubtitles_user"), opensubtitles_pass: v("opensubtitles_pass"),
    iptv: v("iptv"), iptv_type: v("iptv_type"), iptv_url: v("iptv_url"), iptv_user: v("iptv_user"), iptv_pass: v("iptv_pass"),
    iptv_epg_url: v("iptv_epg_url"), iptv_max_streams: v("iptv_max_streams"),
    discord_webhook: v("discord_webhook"), domain: v("domain"), acme_email: v("acme_email"), dojo_https: v("dojo_https"),
    backup_schedule: on === undefined ? undefined : on ? "daily" : "off", backup_keep: v("backup_keep"),
    auto_reboot: v("auto_reboot"),
  };
}
// the one-line summary each folded section shows
function summaries(c) {
  const prov = (c.providers || []).filter(p => p.host.trim());
  const pname = p => (providerFor(p.host) || {}).name || p.host;
  const main = prov.filter(p => !p.isBackup), bk = prov.filter(p => p.isBackup);
  const conns = main.reduce((a, p) => a + (+p.maxConnections || 0), 0);
  const idx = (c.indexers || []).filter(x => x.url || x.name);
  const none = `<span class="meh">None yet</span>`;
  return {
    tz: esc((c.tz || "").replace(/_/g, " ")),
    usenet: prov.length ? `${esc(main.map(pname).join(", ") || "Backup only")}${main.length ? ` · ${conns} connections` : ""}${main.length > 1 ? (c.usenet_balanced ? " · load-balanced" : " · in order") : ""}${bk.length ? ` · backup ${esc(bk.map(pname).join(", "))}` : ""}` : none,
    indexers: idx.length ? esc(idx.map(x => x.name || x.url).join(", ")) : none,
    language: c.language === "none" ? "No preference, the best picture wins" : c.require_language ? `${esc(c.language)} only` : `${esc(c.language)} preferred · waits ${c.wait_minutes || 0} min for it`,
    subtitles: `Podnapisi, Gestdown${c.opensubtitles_user ? ", OpenSubtitles.com" : ""}`,
    livetv: c.iptv ? `On · ${{ xtream: "Xtream Codes", m3u: "M3U playlist" }[c.iptv_type] || "managed in Dispatcharr"}` : "Off",
    notify: [S.pushOn ? "This device" : "", c.discord_webhook ? "Discord" : ""].filter(Boolean).join(" · ") || "Off",
    remote: c.domain ? esc(c.domain) : "Home network only",
    backup: c.backup_schedule === "off" ? `<span class="meh">Off</span>` : `Nightly · keeps ${esc(c.backup_keep)}`,
    updates: c.auto_reboot ? "Automatic · restarts by itself at 04:45 when needed" : "Automatic · you restart when Home asks",
  };
}
const SECTIONS = ["usenet", "indexers", "language", "subtitles", "livetv", "remote", "notify", "backup", "updates", "tz"];
async function pageSettings() {
  const el = $("#page");
  el.innerHTML = `<div class="sk-stack">${SECTIONS.map(() => sk(64)).join("")}</div>`;
  const [s] = await Promise.all([api("/api/settings"), loadCatalog()]);
  const f = settingsForm(s);
  const fold = k => `<details class="fold" id="sec-${k}" data-sec="${k}"><summary><div><h3>${f[k].title}</h3><div class="sum" data-sum="${k}"></div></div>
      <svg class="chev" aria-hidden="true"><use href="#i-chev"/></svg></summary><div class="fold-body">${leadP(f[k])}${f[k].body}</div></details>`;
  el.innerHTML = `<div class="settings">
    <nav class="snav" aria-label="Settings sections">${SECTIONS.map(k => `<a href="#settings" data-go="${k}">${f[k].title}</a>`).join("")}<a href="#settings" data-go="account">Account</a></nav>
    <div><form id="sf" autocomplete="off">${SECTIONS.map(fold).join("")}</form>
      <div class="fold static" id="sec-account"><div class="head"><div><h3>Account</h3><div class="sum">Signed in as ${esc(s.admin_user)} · to change the login, run <code>./bootstrap.sh reconfigure</code> on the server</div></div>
        <button type="button" class="btn" id="logout2">Sign out</button></div></div>
    </div></div>
    <div class="savebar" id="savebar"><div class="inner"><span class="msg" id="smsg"></span>
      <button class="btn quiet" id="discard">Discard</button><button class="btn primary" id="save">Save and apply</button></div></div>`;
  const root = $("#sf");
  bindForm(root);
  const base = collect(root);
  const update = () => {
    const c = collect(root), sum = summaries(c);
    root.querySelectorAll("[data-sum]").forEach(x => x.innerHTML = sum[x.dataset.sum]);
    el.querySelectorAll("[data-go]").forEach(a => a.classList.toggle("warn", /class="(meh|bad)"/.test(sum[a.dataset.go] || "")));
    const n = Object.keys(c).filter(k => JSON.stringify(c[k] ?? "") !== JSON.stringify(base[k] ?? "")).length;
    S.dirty = n > 0;
    $("#savebar").classList.toggle("show", S.dirty);
    $("#smsg").innerHTML = S.dirty ? `${plural(n, "unsaved change")}<small>Saving sets up the apps again; takes about a minute.</small>` : "";

  };
  root.addEventListener("input", update); root.addEventListener("change", update); update();
  bindPush($("#pushbox", root), update);
  $("#logout2").onclick = () => $("#logout").click();
  el.querySelectorAll("[data-go]").forEach(a => a.onclick = e => {
    e.preventDefault();
    const sec = $(`#sec-${a.dataset.go}`); if (sec.tagName === "DETAILS") sec.open = true;
    el.querySelectorAll("[data-go]").forEach(x => x.setAttribute("aria-current", x === a));
    sec.scrollIntoView({ behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: "start" });
  });
  $("#discard").onclick = () => { S.dirty = false; pageSettings(); };
  if (S.openSection) { const a = $(`[data-go="${S.openSection}"]`, el); S.openSection = null; if (a) a.click(); }
  $("#save").onclick = async () => {
    $("#save").disabled = true;
    const r = await api("/api/settings", { method: "POST", body: collect(root) }).catch(() => ({ ok: false }));
    $("#save").disabled = false;
    if (!r.ok) { toast(r.message || "Couldn't save.", "fail"); return; }
    S.dirty = false; $("#savebar").classList.remove("show");
    openJob(r.id, "Applying settings");
  };
}

// ───────────────────────── push notifications on this device (Web Push through the service worker)
const TOPICS = { broken: "Something breaks", ready: "A request is ready to watch", playing: "Someone starts watching",
  update: "A new ninjarr version is out", backup: "A nightly backup didn't happen", restart: "The VM needs a restart" };
function deviceName() {
  const ua = navigator.userAgent;
  const os = /Android/.test(ua) ? "Android" : /iPhone|iPad/.test(ua) ? "iPhone" : /Windows/.test(ua) ? "Windows" : /Mac/.test(ua) ? "Mac" : /Linux/.test(ua) ? "Linux" : "";
  const br = (navigator.userAgentData && navigator.userAgentData.brands || []).map(b => b.brand).find(b => /Vivaldi|Edge|Opera|Brave/.test(b))
    || (/Vivaldi/.test(ua) ? "Vivaldi" : /Edg\//.test(ua) ? "Edge" : /Firefox/.test(ua) ? "Firefox" : /Chrome/.test(ua) ? "Chrome" : /Safari/.test(ua) ? "Safari" : "browser");
  return [os, br].filter(Boolean).join(" · ") + (matchMedia("(display-mode: standalone)").matches ? " (app)" : "");
}
const b64key = s => { const b = atob((s + "=".repeat((4 - s.length % 4) % 4)).replace(/-/g, "+").replace(/_/g, "/")); return Uint8Array.from(b, c => c.charCodeAt(0)); };
async function bindPush(box, onState) {
  if (!box) return;
  // these controls act at once; they aren't part of the settings form below
  ["input", "change"].forEach(t => box.addEventListener(t, e => e.stopPropagation()));
  const body = $("[data-pbody]", box), state = $("[data-pstate]", box);
  const say = (html, cls = "muted") => { body.innerHTML = `<p class="lead-s ${cls}">${html}</p>`; };
  const setOn = on => { S.pushOn = on; state.innerHTML = on ? `<span class="good">On</span>` : ""; onState && onState(); };
  setOn(false);
  if (!window.isSecureContext) {
    say(`Notifications need Dojo over HTTPS. Turn on <i>Dojo too</i> under <b>Away from home</b> below, then open Dojo at <code>https://dojo.<i>your domain</i></code> on this device and come back here.`);
    return;
  }
  if (!("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) {
    say("This browser can't receive push notifications. On Android, Chrome, Vivaldi and Edge can; on an iPhone, add Dojo to the home screen first."); return;
  }
  let reg, info, sub;
  try {
    reg = await Promise.race([navigator.serviceWorker.ready, new Promise((_, no) => setTimeout(() => no(new Error("sw")), 6000))]);
    [info, sub] = await Promise.all([api("/api/push"), reg.pushManager.getSubscription()]);
  } catch (e) { say("Dojo's app part didn't start in this browser, so notifications can't either. Reload the page and try again.", "bad"); return; }
  const me = sub && info.devices.find(d => d.endpoint === sub.endpoint);
  const others = info.devices.filter(d => !sub || d.endpoint !== sub.endpoint);
  const otherList = others.length ? `<p class="small muted" style="margin:14px 0 0">Also on: ${others.map(d =>
      `${esc(d.name || "a browser")} <button type="button" class="linkbtn" data-premove="${esc(d.endpoint)}">remove</button>`).join(" · ")}</p>` : "";
  if (Notification.permission === "denied") {
    say(`Notifications are blocked for Dojo in this browser. Allow them in the site settings (the icon left of the address), then reload.`);
  } else if (!me) {
    body.innerHTML = `<p class="lead-s">Get a notification on this ${/Android|iPhone/.test(navigator.userAgent) ? "phone" : "device"} when something happens, even away from home.</p>
      <button type="button" class="btn primary" data-pon>Turn on for this device</button><p class="result" data-pres></p>${otherList}`;
    $("[data-pon]", body).onclick = async () => {
      const res = $("[data-pres]", body); res.className = "result"; res.textContent = "Asking the browser…";
      try {
        if (await Notification.requestPermission() !== "granted") { res.className = "result fail"; res.textContent = "Not allowed — the browser didn't get permission."; return; }
        let s2 = await reg.pushManager.getSubscription();
        if (s2) await s2.unsubscribe();          // made for another Dojo key: start fresh
        s2 = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64key(info.key) });
        const r = await api("/api/push/subscribe", { method: "POST", body: { subscription: s2.toJSON(), name: deviceName(), topics: Object.keys(TOPICS) } });
        if (!r.ok) throw new Error(r.message || "Dojo didn't take it");
        bindPush(box, onState);
      } catch (e) { res.className = "result fail"; res.textContent = `Couldn't turn them on: ${e.message || e}. Some browsers need Google Play services for this.`; }
    };
  } else {
    setOn(true);
    body.innerHTML = `<p class="lead-s">Tell this device when:</p>
      ${Object.entries(TOPICS).map(([k, n]) => `<label class="check"><input type="checkbox" data-ptopic="${k}" ${me.topics.includes(k) ? "checked" : ""}><span>${n}</span></label>`).join("")}
      <p style="margin:6px 0 0"><button type="button" class="btn" data-ptest>Send a test</button> <button type="button" class="btn quiet" data-poff>Turn off for this device</button></p>
      <p class="result" data-pres></p>${otherList}`;
    const res = $("[data-pres]", body);
    body.querySelectorAll("[data-ptopic]").forEach(x => x.onchange = async () => {
      const topics = [...body.querySelectorAll("[data-ptopic]:checked")].map(y => y.dataset.ptopic);
      const r = await api("/api/push/topics", { method: "POST", body: { endpoint: sub.endpoint, topics } });
      res.className = `result ${r.ok ? "ok" : "fail"}`; res.textContent = r.ok ? "Saved." : r.message || "Couldn't save.";
    });
    $("[data-ptest]", body).onclick = async () => {
      res.className = "result"; res.textContent = "Sending…";
      const r = await api("/api/push/test", { method: "POST", body: { endpoint: sub.endpoint } });
      res.className = `result ${r.ok ? "ok" : "fail"}`; res.textContent = r.message || (r.ok ? "Sent." : "Didn't work.");
    };
    $("[data-poff]", body).onclick = async () => {
      await api("/api/push/remove", { method: "POST", body: { endpoint: sub.endpoint } });
      await sub.unsubscribe().catch(() => {});
      bindPush(box, onState);
    };
  }
  body.querySelectorAll("[data-premove]").forEach(b => b.onclick = async () => {
    await api("/api/push/remove", { method: "POST", body: { endpoint: b.dataset.premove } }); bindPush(box, onState);
  });
}

// ───────────────────────── system: updates, backups, maintenance
const APPNAME = { aiostreams: "AIOStreams", seerr: "Seerr", dispatcharr: "Dispatcharr", prowlarr: "Prowlarr", sonarr: "Sonarr", radarr: "Radarr", bazarr: "Bazarr", emby: "Emby" };
// What an update brings, from GitHub: the changes since this copy, the new version, app versions
function newsPanel(n, cur) {
  const body = t => esc(t).split("\n").map(l => l.trim()).filter(Boolean).join("<br>");
  return `<div class="panel news"><div class="news-head"><h3>What's new${n.version && n.version !== cur ? ` in ${esc(n.version)}` : ""}</h3>
      <span class="muted small">${plural(n.changes.length, "change")}</span></div>
    ${n.restarted ? `<p class="small muted" style="margin:0 0 10px">ninjarr's history was started over, so this is the latest release note rather than every change since yours.</p>` : ""}
    <ul class="news-list">${n.changes.map(c => `<li>${c.body ? `<details><summary><b>${esc(c.title)}</b></summary><p>${body(c.body)}</p></details>` : `<b>${esc(c.title)}</b>`}
      <span class="muted small">${c.when ? esc(when(c.when).split(",")[0]) : ""}</span></li>`).join("")}</ul>
    ${n.apps.length ? `<p class="small" style="margin:12px 0 0"><span class="muted">New app versions:</span> ${n.apps.map(a => `${esc(a.app)} <span class="tag">${esc(a.from)}</span> → <span class="tag">${esc(a.to)}</span>`).join(" · ")}</p>` : ""}
  </div>`;
}

// Google Drive: an encrypted copy of every backup (lib/drive.sh). Connecting runs Google's sign-in
// through the host: Google sends the browser to 127.0.0.1 afterwards, which doesn't load on this
// device, and that page's address (it holds the sign-in code) is pasted back here.
function driveSignin(auth) {
  return `<ol class="dsteps">
      <li><a class="btn primary" href="${esc(auth.url)}" target="_blank" rel="noopener">Sign in with Google</a> and allow access. ninjarr only gets to see the files it puts there.</li>
      <li>Your browser then ends on a page that doesn't load, at <code>127.0.0.1</code>. That's expected: copy that page's whole address from the address bar.</li>
      <li>Paste it here: <span class="paste"><input type="url" id="drivecode" placeholder="http://127.0.0.1:53682/?state=…&amp;code=…" autocomplete="off" spellcheck="false">
        <button class="btn primary" id="drivefinish">Finish</button></span></li>
    </ol>
    <p class="small muted">The link works until ${esc(when(auth.until))}. <a href="#" id="driveagain" class="muted">Start over</a></p>`;
}
function drivePanel(dr, auth) {
  if (auth) return `<div class="panel drive"><div class="task"><div><h3>Connect Google Drive</h3>${driveSignin(auth)}</div></div></div>`;
  if (!dr) return `<div class="panel drive"><div class="task"><div><h3>Google Drive</h3>
      <p>Keep a copy of every backup on your Google Drive, encrypted with a passphrase only you have. If this machine is lost, your setup isn't.</p></div>
      <div class="actions"><button class="btn" id="driveconnect">Connect</button></div></div></div>`;
  const state = dr.ok === true ? `<span class="good">Every backup is copied there${dr.encrypted ? ", encrypted" : ""}.</span> The last copy is from ${esc(when(dr.last_ok))}.`
    : dr.ok === false ? `<span class="meh">The last copy failed: ${esc(dr.message)}</span>${dr.last_ok ? ` The last good one is from ${esc(when(dr.last_ok))}.` : ""}`
    : `Connected. The next backup is copied there${dr.encrypted ? ", encrypted" : ""}.`;
  return `<div class="panel drive"><div class="task"><div><h3>Google Drive <span class="muted small" style="font-weight:400">folder ${esc(dr.folder)}</span></h3><p>${state}</p></div>
      <div class="actions">${dr.has_passphrase ? `<button class="btn plain" id="drivepass">Passphrase</button>` : ""}<button class="btn plain danger" id="driveoff">Disconnect</button></div></div>
    ${dr.files.length ? `<ul class="list blist">${dr.files.map(x => `
      <li><span><span class="when">${esc(when(x.mtime))}</span><span class="size">on Drive</span></span>
      <span class="actions"><button class="btn plain danger" data-drive-restore="${esc(x.name)}" data-when="${esc(when(x.mtime))}">Restore</button></span></li>`).join("")}</ul>` : ""}</div>
    ${dr.has_passphrase ? `<p class="note">Restoring a copy from Drive needs its passphrase. Keep it in your password manager: on a new machine it's the only way to open them.</p>` : ""}`;
}

function driveWire(dr, after = pageSystem) {
  const c = $("#driveconnect"), again = $("#driveagain"), fin = $("#drivefinish"), off = $("#driveoff"), pass = $("#drivepass");
  const connect = async () => { const ok = await quietJob("drive-connect"); if (!ok) toast("Couldn't start Google's sign-in. See .ninjarr-backup.log on the machine.", "fail"); after(); };
  if (c) c.onclick = () => { c.disabled = true; c.textContent = "Starting…"; connect(); };
  if (again) again.onclick = e => { e.preventDefault(); connect(); };
  if (fin) fin.onclick = async () => {
    const url = $("#drivecode").value.trim();
    if (!url) { toast("Paste the address from after the sign-in first.", "fail"); return; }
    fin.disabled = true;
    const d = await api("/api/drive/code", { method: "POST", body: { url } }).catch(() => ({ ok: false }));
    fin.disabled = false;
    if (!d.ok) { toast(d.message || "That didn't work.", "fail"); return; }
    openJob(d.id, "Connecting Google Drive", () => after());
    if (after === pageSystem) watchJobs();
  };
  if (pass) pass.onclick = async () => {
    const d = await api("/api/drive/passphrase").catch(() => ({}));
    await ask({ title: "Passphrase for the backups on Drive", ok: "Done",
      body: `${d.passphrase || "?"}\n\nRestoring a copy from Google Drive needs it. Without it they can't be opened, so keep it in your password manager.` });
  };
  if (off) off.onclick = async () => {
    if (!(await ask({ title: "Disconnect Google Drive?", ok: "Disconnect",
        body: "New backups stay on this machine only. The copies already on Drive stay there, and the passphrase stays in ninjarr.env." }))) return;
    const ok = await quietJob("drive-off");
    toast(ok ? "Google Drive disconnected" : "Couldn't disconnect.", ok ? "ok" : "fail");
    pageSystem();
  };
  document.querySelectorAll("[data-drive-restore]").forEach(x => x.onclick = async () => {
    if (await ask({ title: `Restore the backup from ${x.dataset.when}?`, ok: "Restore",
      body: "It's downloaded from Google Drive and decrypted, then every app goes back to that moment. Your current data is kept on the VM. The stack, Dojo included, restarts for a minute or two." }))
      runJob(`restore-drive ${x.dataset.driveRestore}`);
  });
}

async function pageSystem() {
  const el = $("#page");
  $("#pact").innerHTML = `<button class="btn primary" id="backupnow">Back up now</button>`;
  $("#backupnow").onclick = () => runJob("backup");
  el.innerHTML = `<div class="sk-stack">${sk(76)}${sk(30, "30%")}${sk(150)}${sk(120)}</div>`;
  const [b, v, hr] = await Promise.all([api("/api/backups").catch(() => ({})), api(`/api/versions${S.recheck ? "?fresh=1" : ""}`).catch(() => ({})), api("/api/host").catch(() => ({}))]);
  S.recheck = false;
  const h = hr && hr.host;
  stamp();
  const size = n => n > 2 ** 20 ? `${(n / 2 ** 20).toFixed(1)} MB` : `${Math.ceil(n / 1024)} KB`;
  const upd = v.update_available;
  const images = Object.entries(v.images || {});
  const list = b.backups || [];
  const dr = b.drive;
  el.innerHTML = `
    <div class="card"><div><h3>ninjarr ${esc(v.ninjarr || "?")}${v.commit ? ` <span class="muted small" style="font-weight:400">${esc(v.commit)}</span>` : ""}</h3>
      <div class="small">${upd === true ? `<span class="good">A newer version is available</span>` : upd === false ? `<span class="muted">Up to date · </span><a href="#system" id="recheck" class="muted">check now</a>`
        : `<span class="muted">Couldn't check for updates · </span><a href="#system" id="recheck" class="muted">try again</a>`}</div></div>
      <button class="btn ${upd === true ? "primary" : ""}" data-job="update">${upd === true ? "Update now" : "Update"}</button></div>
    ${upd === true && v.news ? newsPanel(v.news, v.ninjarr) : ""}
    ${(v.tries || []).filter(t => t.state !== "rolled back").map(t => `<div class="panel news try"><div class="news-head"><h3>${esc(APPNAME[t.app] || t.app)} runs ${esc(t.to)}</h3>
        <button class="btn" data-revert="${esc(t.app)}" data-from="${esc(t.from)}">Go back to ${esc(t.from)}</button></div>
      <p class="small muted" style="margin:0">You tried it on ${esc(when(Date.parse(t.when) / 1000))}, newer than ninjarr has tested. It passed the full check. Go back puts ${esc(t.from)} and ${esc(APPNAME[t.app] || t.app)}'s data from before the try back in place; what changed in ${esc(APPNAME[t.app] || t.app)} since is lost. When a ninjarr update brings this version or a newer one, ${esc(APPNAME[t.app] || t.app)} returns to ninjarr's tested versions by itself.</p></div>`).join("")}
    ${(v.tries || []).filter(t => t.state === "rolled back").map(t => `<p class="note"><span class="meh">${esc(APPNAME[t.app] || t.app)} ${esc(t.to)} didn't pass the check here</span> (${esc(when(Date.parse(t.when) / 1000))}), so it went back to ${esc(t.from)} with its data from before.</p>`).join("")}
    ${v.upstream && v.upstream.length ? `<div class="panel news"><div class="news-head"><h3>Newer app versions are out</h3><span class="muted small">not yet tested in ninjarr</span></div>
      <ul class="news-list">${v.upstream.map(a => `<li><span><b>${esc(APPNAME[a.app] || a.app)}</b> <span class="tag">${esc(a.newest)}</span>
        <span class="muted small">${a.newest.replace(/-ls\d+$/, "") === a.running.replace(/-ls\d+$/, "") ? "a rebuild of the version this runs" : `this runs ${esc(a.running)}`}</span></span>
        <button class="btn plain" data-try="${esc(a.app)}" data-tag="${esc(a.newest)}">Try it</button></li>`).join("")}</ul>
      <p class="small muted" style="margin:10px 0 0">ninjarr moves to new versions in its own updates once they're tested. <b>Try it</b> doesn't wait: it saves the app's data, moves it to the new version and runs the full check — if anything fails, the old version and its data come back by themselves.</p></div>` : ""}
    <p class="note">Updating makes a backup first, then moves ninjarr and every app to the versions tested together for the new release.</p>
    ${images.length ? `<details class="versions"><summary>App versions in use (${images.length} apps, all tested together)</summary>
      <div class="tablewrap"><table><tbody>${images.map(([k, t]) => `<tr><td>${esc(k)}</td><td class="tag">${esc(t)}</td></tr>`).join("")}</tbody></table></div></details>` : ""}

    <h2>The server</h2>${machineCard(h)}

    <h2>Backups</h2>
    ${b.visible === false ? `<div class="empty"><h3>Backups are kept elsewhere</h3><p>They go to a folder outside ninjarr's data folder, so Dojo can't list them.</p></div>`
      : list.length ? `<div class="panel"><ul class="list blist">${list.map(x => `
        <li><span><span class="when">${esc(when(x.mtime))}</span><span class="size">${size(x.size)}</span></span>
        <span class="actions"><a class="btn quiet" href="/api/backups/${esc(x.name)}" download>Download</a>
        <button class="btn plain danger" data-restore="${esc(x.name)}" data-when="${esc(when(x.mtime))}">Restore</button>
        <button class="btn plain danger" data-delete="${esc(x.name)}" data-when="${esc(when(x.mtime))}">Delete</button></span></li>`).join("")}</ul></div>
        <p class="note">Each backup holds every app's settings and data (not the movies and shows themselves). ${b.schedule === "off" ? `The nightly backup is off; turn it on in Settings → Backups.` : `One is made every night and the last ${b.keep} are kept.`} ${dr ? "Each one is also copied, encrypted, to Google Drive." : "They're stored on this server, so download one now and then to keep a copy somewhere else, or connect Google Drive below."}</p>`
      : `<div class="empty"><h3>No backups yet</h3><p>Make the first one now. After that, one is made every night.</p></div>`}
    ${drivePanel(dr, b.drive_auth)}

    <h2>Maintenance</h2>
    <div class="panel">
      <div class="task"><div><h3>Re-apply all settings</h3><p>Writes your ninjarr settings into every app again. Safe to run any time; it fixes most problems caused by a setting changed by hand inside an app.</p></div><div class="actions"><button class="btn" data-job="wire">Re-apply</button></div></div>
      <div class="task"><div><h3>Run the full check</h3><p>Tests every app and the connections between them, and shows the log. The same as <code>./bootstrap.sh doctor</code> on the server.</p></div><div class="actions"><button class="btn" data-job="doctor">Run</button></div></div>
    </div>`;
  el.querySelectorAll("[data-job]").forEach(x => x.onclick = async () => {
    if (x.dataset.job === "update" && upd === true && v.news) {
      const n = v.news, to = n.version && n.version !== v.ninjarr ? ` to ${n.version}` : "";
      if (!(await ask({ title: `Update ninjarr${to}?`, ok: "Update",
          body: `${plural(n.changes.length, "change")}${n.apps.length ? `, ${plural(n.apps.length, "app")} on a new version` : ""}. A backup is made first, so you can go back with Restore. Streams stop for a minute or two while the apps restart.` }))) return;
    }
    runJob(x.dataset.job);
  });
  const re = $("#recheck"); if (re) re.onclick = e => { e.preventDefault(); S.recheck = true; pageSystem(); };
  el.querySelectorAll("[data-try]").forEach(x => x.onclick = async () => {
    const name = APPNAME[x.dataset.try] || x.dataset.try;
    if (!(await ask({ title: `Try ${name} ${x.dataset.tag}?`, ok: "Try it",
        body: `First ${name}'s data is saved. Then ${name} moves to ${x.dataset.tag} and the whole stack is checked. If the check fails, the old version and its data come back by themselves. ${name} is offline for a minute or two${x.dataset.try === "dispatcharr" ? ", and live TV with it" : ""}.` }))) return;
    runJob(`try-version ${x.dataset.try} ${x.dataset.tag}`);
  });
  el.querySelectorAll("[data-revert]").forEach(x => x.onclick = async () => {
    const name = APPNAME[x.dataset.revert] || x.dataset.revert;
    if (!(await ask({ title: `Go back to ${name} ${x.dataset.from}?`, ok: "Go back",
        body: `${name} returns to ${x.dataset.from} with its data from before the try. Anything that changed in ${name} since then is lost; the other apps keep everything.` }))) return;
    runJob(`revert-version ${x.dataset.revert}`);
  });
  driveWire(dr);
  el.querySelectorAll("[data-delete]").forEach(x => x.onclick = async () => {
    if (!(await ask({ title: `Delete the backup from ${x.dataset.when}?`, ok: "Delete", body: "It can't be brought back. Your other backups and the running stack stay as they are." }))) return;
    x.disabled = true;
    const ok = await quietJob(`delete-backup ${x.dataset.delete}`);
    toast(ok ? "Backup deleted" : "Couldn't delete that backup.", ok ? "ok" : "fail");
    pageSystem();
  });
  el.querySelectorAll("[data-restore]").forEach(x => x.onclick = async () => {
    if (await ask({ title: `Restore the backup from ${x.dataset.when}?`, ok: "Restore",
      body: "Every app goes back to that moment. Your current data is kept on the VM. The stack, Dojo included, restarts for about a minute." }))
      runJob(`restore ${x.dataset.restore}`);
  });
}

function machineCard(h) {
  if (!h) return `<div class="card"><div><h3>No status yet</h3><div class="small muted">Updating ninjarr sets up automatic security updates and this status of the server.</div></div>
    <button class="btn" data-job="update">Update</button></div>`;
  const days = Math.floor(h.uptime_s / 86400);
  const lc = t => /^(Today|Yesterday)/.test(t) ? t[0].toLowerCase() + t.slice(1) : t;
  const last = h.last_update ? `last updated ${lc(when(h.last_update))}${h.last_update_packages.length ? ` (${plural(h.last_update_packages.length, "package")})` : ""}` : "nothing needed so far";
  return `<div class="card"><div><h3>${esc(h.os)}</h3>
      <div class="small muted">Running without a restart for ${days ? plural(days, "day") : "less than a day"} · kernel ${esc(h.kernel)}</div>

      <div class="small" style="margin-top:6px">${h.auto ? `<span class="good">Security updates install automatically</span> · ${last}` : `<span class="meh">Security updates aren't automatic yet</span>`}</div>
      ${h.reboot_required ? `<div class="small meh" style="margin-top:4px">A restart finishes a security update${h.reboot_packages.length ? ` (${esc(h.reboot_packages.join(", "))})` : ""}${h.auto_reboot ? ", tonight at 04:45" : ""}.</div>` : ""}</div>
    ${h.reboot_required ? `<button class="btn primary" data-job="reboot">Restart now</button>` : h.auto ? "" : `<button class="btn" data-job="update">Set up</button>`}</div>`;
}

// ───────────────────────── first-run setup
const STEPS = [["login", "Login"], ["usenet", "Usenet"], ["indexers", "Indexers"], ["language", "Language"], ["extras", "Extras"], ["build", "Build"]];
async function setupWizard() {
  const [s] = await Promise.all([api("/api/settings"), loadCatalog()]);
  const f = settingsForm(s);
  const bodies = { login: plainSection(f.login), usenet: plainSection(f.usenet), indexers: plainSection(f.indexers), language: plainSection(f.language),
    extras: plainSection(f.subtitles) + plainSection(f.livetv) + plainSection(f.remote), build: `<section class="section"><h2>Ready to build</h2>
      <p class="lead-s">ninjarr saves your answers, downloads the apps (about 5 GB the first time) and connects them. This takes 5 to 15 minutes; the log shows here and in your terminal.</p>
      <p class="result fail" id="berr"></p><button type="button" class="btn primary" id="build">Build my stack</button><p></p></section>` };
  document.title = "Set up ninjarr · Dojo";
  app.innerHTML = `<div class="setupwrap">${brand()}<h1>Set up ninjarr</h1>
    <p class="lead">Six short steps. Test each login as you go; nothing is applied until you build.</p>
    <p class="small muted fromdrive">Moving to a new machine? <a href="#" id="fromdrive">Restore a backup from Google Drive</a> instead.</p>
    <div class="steps">${STEPS.map(([id, n], i) => `<span data-s="${id}">${i + 1}. ${n}</span>`).join("")}</div>
    <form id="wf">${STEPS.map(([id]) => `<div data-step="${id}" class="hidden">${bodies[id]}</div>`).join("")}</form>
    <div class="nav-steps"><button class="btn" id="back">Back</button><button class="btn primary" id="next">Next</button></div></div>`;
  const root = $("#wf");
  bindForm(root);
  if (!s.indexers.length) $("#indexers", root).insertAdjacentHTML("beforeend", indexerEntry({}));
  let i = 0;
  const check = id => {
    const v = n => ($(`[name=${n}]`, root) || {}).value || "";
    if (id === "login") {
      if (!/^[A-Za-z0-9._-]+$/.test(v("admin_user"))) return "The username can have letters, digits, dot, dash and underscore.";
      const p = v("admin_password"); if (p.length < 8 || p.includes(",") || p.includes("'") || p.trim() !== p) return "The password needs 8+ characters, no comma or apostrophe, and no space at either end.";
    }
    if (id === "usenet" && !root.querySelector("[data-provider] [name=host]").value.trim()) return "Add your usenet provider's server.";
    return "";
  };
  const show = () => {
    STEPS.forEach(([id], n) => {
      $(`[data-step=${id}]`, root).classList.toggle("hidden", n !== i);
      const tag = $(`[data-s=${id}]`); n === i ? tag.setAttribute("aria-current", "step") : tag.removeAttribute("aria-current");
      tag.classList.toggle("done", n < i);
    });
    $("#back").style.visibility = i ? "visible" : "hidden";
    $("#next").classList.toggle("hidden", i === STEPS.length - 1);
    window.scrollTo(0, 0);
  };
  $("#back").onclick = () => { i = Math.max(0, i - 1); show(); };
  $("#next").onclick = () => {
    const err = check(STEPS[i][0]);
    if (err) { toast(err, "fail"); return; }
    document.querySelectorAll(".toast.t-fail").forEach(t => t.remove());
    i = Math.min(STEPS.length - 1, i + 1); show();
  };
  $("#fromdrive").onclick = e => { e.preventDefault(); setupRestore(); };
  $("#build").onclick = async () => {
    $("#build").disabled = true; $("#berr").textContent = "";
    const r = await api("/api/settings", { method: "POST", body: collect(root) });
    if (!r.ok) { $("#berr").textContent = r.message; $("#build").disabled = false; return; }
    openJob(r.id, "Building your stack", st => {
      $("#build").disabled = false;
      if (st === "ok") {
        $("#jobstate").innerHTML = `<span class="state-ok">Done. Close this and sign in with the login you just chose.</span>`;
        $("#jobclose").onclick = () => { $("#jobdlg").close(); boot(); };
      }
    });
  };
  show();
}

// First-run setup on a new machine: everything back from a backup on Google Drive (lib/drive.sh)
// instead of the questions. The backup brings ninjarr.env, so the login is the one it had.
async function setupRestore() {
  const d = await api("/api/drive/setup").catch(() => ({}));
  const files = d.files || [];
  document.title = "Restore from Google Drive · Dojo";
  const body = d.auth ? `<h2>Connect Google Drive</h2>${driveSignin(d.auth)}`
    : !d.connected ? `<h2>Connect Google Drive</h2>
        <p class="lead-s">Sign in with the Google account your old machine copied its backups to. ninjarr only sees the files it put there.</p>
        <button type="button" class="btn primary" id="driveconnect">Connect</button><p></p>`
    : !files.length ? `<h2>No backups found</h2>
        <p class="lead-s">This Google account has no ninjarr backups in its <b>ninjarr-backups</b> folder. Maybe they're on another account?</p>
        <button type="button" class="btn" id="driveconnect">Use another account</button><p></p>`
    : `<h2>Pick a backup</h2>
        <div class="panel"><ul class="list blist">${files.map((x, i) => `<li><label class="pick"><input type="radio" name="bk" value="${esc(x.name)}"${i ? "" : " checked"}>
          <span class="when">${esc(when(x.mtime))}</span>${i ? "" : `<span class="size">newest</span>`}</label></li>`).join("")}</ul></div>
        <label class="field" style="margin-top:16px"><span>Passphrase for the backups on Drive</span><input type="password" id="drivepw" autocomplete="off"></label>
        <p class="lead-s">Every app comes back as it was in that backup: settings, library, watch history, and the same login. This takes 5 to 15 minutes; the log shows here and in your terminal.</p>
        <p class="result fail" id="rerr"></p><button type="button" class="btn primary" id="restore">Restore my stack</button>
        <a href="#" id="driveagain2" class="muted small" style="margin-left:12px">Use another account</a><p></p>`;
  app.innerHTML = `<div class="setupwrap">${brand()}<h1>Restore from Google Drive</h1>
    <p class="lead">Your stack exactly as it was, from the encrypted copy your old machine kept on Google Drive.</p>
    <section class="section drive">${body}</section>
    <p class="small"><a href="#" id="tonew" class="muted">Set up from scratch instead</a></p></div>`;
  $("#tonew").onclick = e => { e.preventDefault(); setupWizard(); };
  driveWire(null, setupRestore);
  const again2 = $("#driveagain2");
  if (again2) again2.onclick = async e => { e.preventDefault(); await quietJob("drive-connect"); setupRestore(); };
  const go = $("#restore");
  if (go) go.onclick = async () => {
    const name = (document.querySelector("[name=bk]:checked") || {}).value, passphrase = $("#drivepw").value;
    $("#rerr").textContent = "";
    if (!passphrase && name.endsWith(".gpg")) { $("#rerr").textContent = "Type the passphrase first."; return; }
    go.disabled = true;
    const r = await api("/api/drive/restore", { method: "POST", body: { name, passphrase } }).catch(() => ({ ok: false }));
    if (!r.ok) { $("#rerr").textContent = r.message || "That didn't start."; go.disabled = false; return; }
    openJob(r.id, "Restoring your stack", st => {
      go.disabled = false;
      if (st === "ok") {
        $("#jobstate").innerHTML = `<span class="state-ok">Done. Close this and sign in with the login from your backup.</span>`;
        $("#jobclose").onclick = () => { $("#jobdlg").close(); boot(); };
      }
    });
  };
}

boot();
