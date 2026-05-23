// Tiny vanilla-JS client. Hash-routed:
//   #/browse/<path>     (path may be empty, "Movies", "Movies/Action", ...)
//   #/play/<path>
//
// All routing is driven by `location.hash` so the server doesn't have to know
// about client routes.

const app = document.getElementById("app");
const crumbs = document.getElementById("crumbs");

function encodePath(p) {
  return p
    .split("/")
    .filter(Boolean)
    .map(encodeURIComponent)
    .join("/");
}

function parseRoute() {
  const h = location.hash.replace(/^#/, "") || "/browse/";
  const m = h.match(/^\/(browse|play)\/(.*)$/);
  if (!m) return { kind: "browse", path: "" };
  const rawPath = m[2] || "";
  const path = rawPath
    .split("/")
    .map(decodeURIComponent)
    .filter(Boolean)
    .join("/");
  return { kind: m[1], path };
}

function renderCrumbs(path) {
  crumbs.innerHTML = "";
  const parts = path.split("/").filter(Boolean);
  let acc = "";
  const root = document.createElement("a");
  root.href = "#/browse/";
  root.textContent = "/";
  crumbs.appendChild(root);
  parts.forEach((p, i) => {
    acc = acc ? acc + "/" + p : p;
    const sep = document.createElement("span");
    sep.className = "sep";
    sep.textContent = "/";
    crumbs.appendChild(sep);
    if (i + 1 < parts.length) {
      const a = document.createElement("a");
      a.href = "#/browse/" + encodePath(acc);
      a.textContent = p;
      crumbs.appendChild(a);
    } else {
      const span = document.createElement("span");
      span.textContent = p;
      crumbs.appendChild(span);
    }
  });
}

async function getJSON(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
  return r.json();
}

function el(tag, props, ...children) {
  const e = document.createElement(tag);
  Object.assign(e, props || {});
  for (const c of children.flat()) {
    if (c == null) continue;
    e.append(c.nodeType ? c : document.createTextNode(c));
  }
  return e;
}

async function renderBrowse(path) {
  renderCrumbs(path);
  app.replaceChildren(el("p", { className: "muted" }, "loading…"));
  let data;
  try {
    data = await getJSON("/api/browse?path=" + encodeURIComponent(path));
  } catch (e) {
    app.replaceChildren(el("div", { className: "error" }, "browse failed: " + e.message));
    return;
  }
  const grid = el("div", { className: "grid" });
  if (data.entries.length === 0) {
    grid.append(el("p", null, "(empty directory)"));
  }
  for (const entry of data.entries) {
    const full = path ? path + "/" + entry.name : entry.name;
    if (entry.kind === "dir") {
      const tile = el(
        "a",
        { className: "tile dir", href: "#/browse/" + encodePath(full) },
        el("div", { className: "name" }, entry.name),
        el("div", { className: "meta" }, `${entry.children} entries`)
      );
      grid.append(tile);
    } else {
      const meta = [`${prettySize(entry.size)}`];
      if (entry.ext) meta.push(entry.ext);
      const badge = entry.decision
        ? el("span", { className: "badge " + entry.decision }, entry.decision)
        : null;
      const tile = el(
        "a",
        { className: "tile file", href: "#/play/" + encodePath(full) },
        el("div", { className: "name" }, entry.name, badge),
        el("div", { className: "meta" }, meta.join(" · "))
      );
      grid.append(tile);
    }
  }
  app.replaceChildren(grid);
}

function prettySize(n) {
  if (!n) return "?";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) {
    n /= 1024;
    i++;
  }
  return `${n.toFixed(n < 10 ? 2 : 1)} ${u[i]}`;
}

let activeHls = null;

function teardownPlayer() {
  if (activeHls) {
    activeHls.destroy();
    activeHls = null;
  }
}

async function renderPlay(path) {
  teardownPlayer();
  renderCrumbs(path);
  app.replaceChildren(el("p", null, "loading…"));
  let info;
  try {
    info = await getJSON("/api/file?path=" + encodeURIComponent(path));
  } catch (e) {
    app.replaceChildren(el("div", { className: "error" }, "load failed: " + e.message));
    return;
  }

  if (info.decision === "unsupported") {
    const vc = info.probe?.streams?.find((s) => s.codec_type === "video")?.codec_name || "?";
    app.replaceChildren(
      el("div", { className: "error" }, `unsupported: video codec ${vc} is not in this device's capability matrix.`),
      detailsBlock(info)
    );
    return;
  }

  const video = el("video", { controls: true, playsInline: true, autoplay: true });

  const loadingText = el("div", { className: "player-loading-text" }, "loading…");
  const loadingOverlay = el("div", { className: "player-loading" }, loadingText);
  attachLoadingOverlay(video, loadingOverlay, loadingText);

  const wrap = el("div", { className: "player" }, video, loadingOverlay);

  // Subtitle dropdown — sidecar + embedded text tracks.
  const subOpts = [el("option", { value: "" }, "subtitles: off")];
  info.sidecars?.forEach((s, i) => {
    subOpts.push(el("option", { value: "sidecar:" + i }, `${s.language || "?"} (sidecar ${s.format})`));
  });
  info.embedded_subs?.forEach((s) => {
    if (s.format === "text") {
      subOpts.push(el("option", { value: "embedded:" + s.index }, `${s.language || "?"} (embedded ${s.codec || "text"})`));
    }
  });
  const subSelect = el("select", null, ...subOpts);

  const controls = el("div", { className: "controls" }, el("label", null, "subs:"), subSelect);

  wrap.append(controls, detailsBlock(info));
  app.replaceChildren(wrap);

  if (info.decision === "direct") {
    video.src = info.urls.raw;
  } else {
    const master = info.urls.master;
    if (window.Hls && window.Hls.isSupported()) {
      const hls = new window.Hls({ debug: false });
      activeHls = hls;
      hls.loadSource(master);
      hls.attachMedia(video);
    } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
      video.src = master;
    } else {
      app.replaceChildren(el("div", { className: "error" }, "no HLS support in this browser"));
      return;
    }
  }

  subSelect.addEventListener("change", () => {
    [...video.querySelectorAll("track")].forEach((t) => t.remove());
    const val = subSelect.value;
    if (!val) return;
    const t = document.createElement("track");
    t.kind = "subtitles";
    t.default = true;
    t.label = subSelect.selectedOptions[0].textContent;
    t.src = `/api/subs?path=${encodeURIComponent(path)}&track=${encodeURIComponent(val)}`;
    t.srclang = "en";
    video.append(t);
    // Activate it explicitly.
    setTimeout(() => {
      [...video.textTracks].forEach((tt) => {
        tt.mode = "showing";
      });
    }, 50);
  });
}

// Show "loading…" with elapsed-time feedback whenever the video is buffering.
// Hides on `playing`; shows on `loadstart` / `waiting` / `stalled`. The text
// upgrades after a few seconds so a long wait reads as "still working" rather
// than a hung spinner.
function attachLoadingOverlay(video, overlay, textNode) {
  let timer = null;
  let startedAt = 0;

  const show = () => {
    overlay.classList.add("show");
    if (timer) return;
    startedAt = performance.now();
    const tick = () => {
      const elapsed = (performance.now() - startedAt) / 1000;
      if (elapsed < 3) {
        textNode.textContent = "loading…";
      } else if (elapsed < 15) {
        textNode.textContent = `indexing… (${elapsed.toFixed(0)}s)`;
      } else {
        textNode.textContent = `still indexing — large file (${elapsed.toFixed(0)}s)`;
      }
    };
    tick();
    timer = setInterval(tick, 500);
  };
  const hide = () => {
    overlay.classList.remove("show");
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
  };

  show();
  video.addEventListener("playing", hide);
  video.addEventListener("waiting", show);
  video.addEventListener("stalled", show);
  video.addEventListener("error", hide);
}

function detailsBlock(info) {
  if (!new URLSearchParams(window.location.search).has("debug")) {
    return document.createDocumentFragment();
  }
  return el("details", null,
    el("summary", null, `${info.decision} — ${info.path}`),
    el("pre", null, JSON.stringify(info.probe, null, 2)),
  );
}

function render() {
  const r = parseRoute();
  if (r.kind === "play") renderPlay(r.path);
  else renderBrowse(r.path);
}

window.addEventListener("hashchange", render);
window.addEventListener("DOMContentLoaded", () => {
  if (!location.hash) location.hash = "#/browse/";
  render();
});
