import AgentsKitCore
import Foundation

/// The views the app's own `agents` server serves (#187, MCP Apps): each `ui://` resource,
/// and the tools that draw one or that only a view may call.
///
/// Dashboard and test views served by the app's own MCP server.
public enum AppViewCatalog {
    /// A tool with a view, or one only a view may call.
    public struct Tool: Sendable {
        public var definition: JSONValue
        public var name: String { definition["name"]?.stringValue ?? "" }
        /// Who may call it: `model`, `app`, or both. The spec's default is both.
        public var visibility: [String] {
            definition["_meta"]?["ui"]?["visibility"]?.arrayValue?.compactMap(\.stringValue) ?? ["model", "app"]
        }
        public var resourceURI: String? { definition["_meta"]?["ui"]?["resourceUri"]?.stringValue }
        public var forModel: Bool { visibility.contains("model") }
        public var forApp: Bool { visibility.contains("app") }
    }

    /// A `ui://` resource.
    public struct Resource: Sendable {
        public var uri: String
        public var name: String
        public var title: String
        public var description: String
        public var html: String
        /// The resource's `_meta.ui`: its `csp`, `prefersBorder`.
        public var meta: JSONValue?
    }

    /// Whether the test view and its tools are offered: read once, from the daemon's
    /// environment. Each call below takes it as an argument, so a test says its own.
    public static let offersTestView = ProcessInfo.processInfo.environment["AGENTS_TEST_VIEWS"] == "1"

    public static let testViewURI = "ui://agents/test-view"
    public static let showTestView = "show_test_view"
    public static let testViewCount = "test_view_count"
    public static let dashboardURI = "ui://agents/dashboard"

    /// Every tool with a view or for a view, as offered now.
    public static func tools(testView: Bool = offersTestView) -> [Tool] {
        [Tool(definition: AppService.readDashboardTool), dashboardActionTool]
            + (testView ? [showTestViewTool, testViewCountTool] : [])
    }

    /// Every resource, as offered now.
    public static func resources(testView: Bool = offersTestView) -> [Resource] {
        [Self.dashboard] + (testView ? [Self.testView] : [])
    }

    /// The tool called `name`, matched on the end as every app tool is: a runtime may put
    /// the server's name in front.
    public static func tool(named name: String, testView: Bool = offersTestView) -> Tool? {
        tools(testView: testView).filter { name == $0.name || name.hasSuffix("_" + $0.name) || name.hasSuffix("__" + $0.name)
            || name.hasSuffix("-" + $0.name) || name.hasSuffix("." + $0.name) || name.hasSuffix("/" + $0.name) }
            .max { $0.name.count < $1.name.count }
    }

    public static func resource(_ uri: String, testView: Bool = offersTestView) -> Resource? {
        resources(testView: testView).first { $0.uri == uri }
    }

    // MARK: The test view

    static let dashboardActionTool = Tool(definition: [
        "name": "dashboard_action", "title": "Dashboard action",
        "description": "Perform a Dashboard action requested by the person.",
        "inputSchema": ["type": "object", "properties": ["action": ["type": "string"],
                                                    "id": ["type": "string"], "step": ["type": "integer"]],
                        "required": ["action"]],
        "_meta": ["ui": ["resourceUri": .string(dashboardURI), "visibility": ["app"]]],
    ])

    static let dashboard = Resource(uri: dashboardURI, name: "dashboard", title: "Dashboard",
                                    description: "The project's live Dashboard.", html: dashboardHTML,
                                    meta: ["ui": ["prefersBorder": false]])

    static let dashboardHTML = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
    :root{color-scheme:light dark;font:15px -apple-system,BlinkMacSystemFont,sans-serif;color:CanvasText;background:Canvas}
    html,body{height:100%}body{margin:0;padding:20px;box-sizing:border-box;overflow:auto}
    header{display:flex;align-items:center;justify-content:flex-end;gap:12px}h1{font-size:22px;margin:0 auto 12px 0}
    button{font:inherit;color:inherit;background:transparent;border:1px solid color-mix(in srgb,CanvasText 20%,transparent);border-radius:8px;padding:6px 10px;cursor:pointer}
    button:disabled{opacity:.45;cursor:default}select{font:inherit;color:inherit;background:Canvas;border:1px solid color-mix(in srgb,CanvasText 20%,transparent);border-radius:7px;max-width:100%;font-size:12px}.small{font-size:12px}.error{color:#b32d37}
    section{margin:20px 0}h2{font-size:12px;text-transform:uppercase;opacity:.65} .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:10px}
    article{border:1px solid color-mix(in srgb,CanvasText 16%,transparent);border-radius:12px;padding:14px;min-width:0}article.wide{grid-column:1/-1}
    article.stale{opacity:.48}article header{gap:4px}article h3{font-size:14px;margin:0 auto 10px 0;overflow-wrap:anywhere}
    .delta{font-size:13px}.delta.good{color:#248a53}.delta.bad{color:#cb3946}
    p{margin:6px 0;overflow-wrap:anywhere}.value{font-size:24px;font-weight:600}.tile-actions{display:flex;gap:4px;flex-wrap:wrap;margin-top:10px}.tile-actions button{font-size:12px;padding:3px 6px}
    small{opacity:.65}table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:6px;border-bottom:1px solid color-mix(in srgb,CanvasText 12%,transparent)}
    svg{width:100%;height:36px}a{color:LinkText}pre{white-space:pre-wrap;overflow-wrap:anywhere;max-height:240px;overflow:auto}
    .light{display:inline-block;width:9px;height:9px;border-radius:50%;background:#888}.light.ok{background:#248a53}.light.warn{background:#d38b00}.light.bad{background:#cb3946}
    dialog{color:CanvasText;background:Canvas;border:1px solid color-mix(in srgb,CanvasText 25%,transparent);border-radius:12px;max-width:min(90vw,560px)}
    dialog::backdrop{background:#0008}dt{font-weight:600}dd{margin:0 0 10px}a,button{touch-action:manipulation}
    </style></head><body><header><button id="hidden" type="button">Show hidden</button><button id="update" type="button" disabled>Update now</button></header>
    <p id="status" class="small"></p><p id="error" class="error" role="alert"></p><main id="root"><p>Waiting for Dashboard…</p></main><p class="small">Tiles and their trends are files in .agents/dashboard/ in this project, which you may commit.</p><dialog id="details"></dialog>
    <script>
    (() => {
      const root = document.querySelector("#root");
      const hidden = document.querySelector("#hidden");
      const update = document.querySelector("#update");
      let showHidden = false, latest = null, nextID = 1, isMobile = false;
      const expandedTables = new Set();
      const waiting = new Map();
      const ref = Date.UTC(2001, 0, 1);
      const post = (message) => window.parent.postMessage(Object.assign({ jsonrpc: "2.0" }, message), "*");
      const request = (method, params) => new Promise((resolve, reject) => {
        const id = nextID++; waiting.set(id, { resolve, reject }); post({ id, method, params });
      });
      const notify = (method, params) => post({ method, params });
      const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
      const at = (v) => {
        if (v instanceof Date) return v;
        if (typeof v === "number") return new Date(v > 1e11 ? v : ref + v * 1000);
        const d = new Date(v); return Number.isNaN(d.getTime()) ? null : d;
      };
      const safeURL = (text) => { try { const u = new URL(text); return ["http:", "https:", "mailto:"].includes(u.protocol) ? u.href : null; } catch { return null; } };
      const action = async (name, id, extra = {}) => {
        try {
          const answer = await request("tools/call", { name: "dashboard_action", arguments: { action: name, id, ...extra } });
          if (answer.isError) throw new Error(answer.content?.[0]?.text || "Action failed");
          if (name === "read_page") return answer.structuredContent?.text || "";
        } catch (e) { document.querySelector("#error").textContent = e.message || String(e); }
      };
      const button = (label, actionName, id, extra = "") => `<button type="button" data-action="${actionName}" data-id="${esc(id)}" ${extra}>${label}</button>`;
      const date = (value) => { const d = at(value); return d ? d.toLocaleString() : "unknown"; };
      const markdown = (text) => esc(text).replace(/\\*\\*([^*]+)\\*\\*/g, "<strong>$1</strong>").replace(/\\n/g, "<br>");
      const refreshUpdate = (data) => {
        const lastStart = at(data?.update?.lastStartedAt);
        update.disabled = !data?.update || data.update.isRunning || !!data.update.blocked ||
          !!lastStart && Date.now() < lastStart.getTime() + 300000;
        update.textContent = data?.update?.isRunning ? "Updating…" : "Update now";
        const u = data?.update;
        const line = u?.isRunning ? `${u.name || "Dashboard update"} is running` : u?.blocked ? `Update now cannot start: ${u.blocked}` :
          lastStart ? `Last update ${lastStart.toLocaleString()}${u.lastFailed ? " (did not finish)" : ""}` : "";
        document.querySelector("#status").textContent = [line, data?.note].filter(Boolean).join(" · ");
      };
      function draw(data) {
        latest = data;
        refreshUpdate(data);
        if (!data || !Array.isArray(data.tiles)) { root.innerHTML = "<p>Dashboard data is unavailable.</p>"; return; }
        const tiles = data.tiles.filter((x) => showHidden || !x.tile?.hidden);
        if (!tiles.length) { root.innerHTML = `<p>${data.tiles.length ? "Every tile is hidden. Show hidden brings them back." : "No tiles yet. Agents keep tiles here with set_tile."}</p>`; return; }
        const groups = new Map(), placed = new Set();
        const byID = new Map(tiles.map((v) => [v.id, v]));
        for (const section of data.order?.sections || []) {
          const name = section.title || "";
          const items = (section.tiles || []).map((id) => byID.get(id)).filter(Boolean);
          for (const item of items) placed.add(item.id);
          if (items.length) groups.set(name, [...(groups.get(name) || []), ...items]);
        }
        for (const item of tiles) if (!placed.has(item.id)) {
          const name = item.tile?.section || "";
          if (!groups.has(name)) groups.set(name, []);
          groups.get(name).push(item);
        }
        root.innerHTML = [...groups].map(([name, items], sectionIndex) => `<section>${name ? `<h2>${esc(name)} ${button("↑", "move_section", "", `data-section="${esc(name)}" data-step="-1" ${sectionIndex === 0 ? "disabled" : ""}`)} ${button("↓", "move_section", "", `data-section="${esc(name)}" data-step="1" ${sectionIndex === groups.size - 1 ? "disabled" : ""}`)}</h2>` : ""}<div class="grid">${items.map((v, i) => tile(v, i, items.length, [...groups.keys()], name)).join("")}</div></section>`).join("");
      }
      function tile(v, index, count, sections, currentSection) {
        const t = v.tile;
        if (!t) return `<article class="wide"><h3>${esc(v.id)}</h3><p class="error">${esc(v.problem || "Unreadable tile")}</p></article>`;
        const set = at(v.setAt), now = at(latest.now) || new Date();
        const stale = t.type !== "page" && (!set || (now.getTime() - set.getTime() > (t.stale_after_hours || 24) * 3600000));
        let body = "";
        switch (t.type) {
          case "number": {
            const n = t.number || {}, pts = v.points || [];
            const values = pts.map((x) => x.value), min = Math.min(...values), max = Math.max(...values);
            const start = pts.length ? at(pts[0].at)?.getTime() : 0;
            const span = Math.max((pts.length ? at(pts[pts.length - 1].at)?.getTime() : 0) - start, 1);
            const line = pts.length > 1 ? pts.map((p) => `${((at(p.at).getTime() - start) * 160 / span).toFixed(1)},${(max === min ? 13 : 26 - (p.value - min) * 26 / (max - min)).toFixed(1)}`).join(" ") : "";
            const older = pts.filter((p) => at(p.at).getTime() <= (set || now).getTime() - 86400000);
            const base = older.length ? older[older.length - 1] : pts[0];
            const delta = pts.length > 1 && base ? n.value - base.value : 0;
            const good = !stale && n.good && delta ? (delta > 0) === (n.good === "up") : null;
            const trend = delta ? `<span class="delta ${good === null ? "" : good ? "good" : "bad"}">${delta > 0 ? "▲" : "▼"}${esc(Math.abs(delta).toLocaleString())}</span>` : "";
            body = `<p class="value">${esc(Number(n.value ?? 0).toLocaleString())} ${esc(n.unit || "")} ${trend}</p>${line ? `<svg viewBox="0 0 160 26" preserveAspectRatio="none" aria-label="Trend"><polyline fill="none" stroke="currentColor" stroke-width="2" points="${line}"/></svg>` : ""}`;
            break;
          }
          case "status": body = `<p><span class="light ${esc(stale ? "unknown" : t.status?.level || "unknown")}" aria-label="${esc(stale ? "unknown" : t.status?.level || "unknown")}"></span> ${esc(t.status?.line || "")}${t.status?.since ? `<br><small>since ${esc(t.status.since)}</small>` : ""}</p>`; break;
          case "table": {
            const rows = t.table?.rows || [], shown = isMobile && !expandedTables.has(v.id) ? rows.slice(0, 5) : rows;
            body = `<table><thead><tr>${(t.table?.columns || []).map((x) => `<th>${esc(x)}</th>`).join("")}</tr></thead><tbody>${shown.map((r) => `<tr>${r.map((c) => { const text = typeof c === "string" ? c : c.text; const url = safeURL(c?.url); return `<td>${url ? `<a href="${esc(url)}" target="_blank" rel="noopener noreferrer">${esc(text)}</a>` : esc(text)}</td>`; }).join("")}</tr>`).join("")}</tbody></table>${isMobile && rows.length > 5 ? button(expandedTables.has(v.id) ? "Show less" : `Show all ${rows.length} rows`, "expand_table", v.id) : ""}`;
            break;
          }
          case "note": body = `<p>${markdown(t.note?.markdown || "")}</p>`; break;
          case "link": {
            const link = t.link || {}, url = safeURL(link.url);
            body = url ? `<p><a href="${esc(url)}" target="_blank" rel="noopener noreferrer">${esc(new URL(url).host)} ↗</a></p>`
              : link.session ? button("A session →", "open_session", v.id)
              : link.workflow ? button(`Workflow ${esc(link.workflow)} →`, "open_workflow", v.id)
              : link.file ? button(`${esc(link.file)} →`, "open_page", v.id) : "";
            break;
          }
          case "page": body = `<p class="small">${esc(t.page?.file || "")}</p><pre id="page-${esc(v.id)}">Reading…</pre>${button("Open", "open_page", v.id)}`; break;
        }
        const wide = ["table", "note", "page"].includes(t.type) ? "wide" : "";
        const seconds = set ? Math.max(0, Math.floor((now - set) / 1000)) : null;
        const age = t.type === "page" ? "live" : seconds === null ? "age unknown" :
          stale ? `${Math.max(1, Math.floor(seconds / 3600))} h old` :
          seconds < 60 ? "just now" : seconds < 3600 ? `${Math.floor(seconds / 60)} min ago` :
          seconds < 86400 ? `${Math.floor(seconds / 3600)} h ago` : `${Math.floor(seconds / 86400)} days ago`;
        return `<article class="${wide} ${stale ? "stale" : ""}"><header><h3>${esc(t.title)}${t.hidden ? " (hidden)" : ""}</h3>${button("Details", "details", v.id)}</header>${body}<small>${esc(v.keeper?.name || "nobody")} · ${esc(age)}</small><div class="tile-actions">${button("Keeper", "open_keeper", v.id, !v.keeper?.id ? "disabled" : "")}${button("↑", "move", v.id, index === 0 ? "disabled" : "data-step='-1'")}${button("↓", "move", v.id, index === count - 1 ? "disabled" : "data-step='1'")}${button(t.hidden ? "Show" : "Hide", t.hidden ? "show" : "hide", v.id)}${sections.length > 1 ? `<select data-id="${esc(v.id)}" aria-label="Move to section"><option value="">Move to section…</option>${sections.filter((x) => x !== currentSection).map((x) => `<option value="${esc(x || "__none__")}">${esc(x || "No section")}</option>`).join("")}</select>` : ""}${button("Remove", "remove", v.id)}</div></article>`;
      }
      root.addEventListener("click", async (event) => {
        const link = event.target.closest("a[href]");
        if (link) { event.preventDefault(); await request("ui/open-link", { url: link.href }); return; }
        const button = event.target.closest("button[data-action]"); if (!button) return;
        const id = button.dataset.id, name = button.dataset.action;
        const v = latest?.tiles?.find((x) => x.id === id); if (!v && name !== "move_section") return;
        if (name === "details") {
          const t = v.tile || {}, dialog = document.querySelector("#details");
          const recent = (v.recent || []).slice().reverse().map((p) => `<li>${esc(date(p.at))}: ${esc(p.value)}</li>`).join("");
          const keepers = (v.keeperChanges || []).map((change) => `<li>${esc(date(change.at))}: ${esc(change.from)} → ${esc(change.to)}</li>`).join("");
          dialog.innerHTML = `<h2>${esc(t.title || id)}</h2><dl><dt>File</dt><dd>.agents/dashboard/${esc(id)}.json</dd><dt>Kept by</dt><dd>${esc(v.keeper?.name || "nobody")} (${esc(v.keeper?.state || "unknown")})</dd><dt>Set</dt><dd>${date(v.setAt)}</dd><dt>Source</dt><dd>${esc(t.source || "unknown")}</dd><dt>Changed outside Agents</dt><dd>${v.changedOutside ? "Yes" : "No"}</dd><dt>Problem</dt><dd>${esc(v.problem || "none")}</dd>${t.type === "number" ? `<dt>History</dt><dd>.agents/dashboard/history/${esc(id)}.jsonl</dd>` : ""}</dl>${recent ? `<h3>Recent values</h3><ol>${recent}</ol>` : ""}${keepers ? `<h3>Keeper changes</h3><ol>${keepers}</ol>` : ""}<button id="close-details">Done</button>`;
          dialog.showModal(); dialog.querySelector("#close-details").onclick = () => dialog.close(); return;
        }
        if (name === "expand_table") { expandedTables.has(id) ? expandedTables.delete(id) : expandedTables.add(id); draw(latest); void loadPages(); return; }
        if (name === "open_session") { await action("open_link", id, { kind: "agent" }); return; }
        if (name === "open_workflow") { await action("open_link", id, { kind: "workflow" }); return; }
        if (name === "move" || name === "move_section") { await action(name, id, { step: Number(button.dataset.step), ...(name === "move_section" ? { section: button.dataset.section } : {}) }); return; }
        await action(name, id);
      });
      root.addEventListener("change", async (event) => {
        const select = event.target.closest("select[data-id]");
        if (select && select.value !== "") await action("move", select.dataset.id, { section: select.value === "__none__" ? "" : select.value });
      });
      const loadPages = async () => {
        for (const v of latest?.tiles || []) if (v.tile?.type === "page") {
          const place = document.getElementById(`page-${v.id}`); if (!place) continue;
          place.textContent = await action("read_page", v.id) || "This page is unavailable.";
        }
      };
      update.onclick = () => action("update");
      setInterval(() => { if (latest?.update) refreshUpdate(latest); }, 15000);
      hidden.onclick = () => {
        showHidden = !showHidden;
        hidden.textContent = showHidden ? "Hide hidden" : "Show hidden";
        if (latest) { draw(latest); void loadPages(); }
      };
      window.addEventListener("message", (event) => {
        const m = event.data;
        if (!m || m.jsonrpc !== "2.0") return;
        if (m.id !== undefined && !m.method && waiting.has(m.id)) {
          const w = waiting.get(m.id); waiting.delete(m.id);
          return m.error ? w.reject(new Error(m.error.message)) : w.resolve(m.result);
        }
        if (m.method === "ui/notifications/tool-result") { draw((m.params && m.params.structuredContent) || {}); void loadPages(); }
        if (m.method === "ui/resource-teardown") post({ id: m.id, result: {} });
        if (m.method === "ping") post({ id: m.id, result: {} });
      });
      request("ui/initialize", {
        protocolVersion: "2026-01-26",
        clientInfo: { name: "agents-dashboard", version: "1.0.0" },
        appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] },
      }).then((result) => {
        const ctx = result.hostContext || {};
        isMobile = ctx.platform === "mobile";
        const vars = (ctx.styles && ctx.styles.variables) || {};
        for (const [key, value] of Object.entries(vars)) if (value) document.documentElement.style.setProperty(key, value);
        if (ctx.theme) document.documentElement.style.colorScheme = ctx.theme;
        notify("ui/notifications/initialized", {});
      }).catch((e) => { root.innerHTML = "<p>The host refused: " + esc(e.message) + "</p>"; });
    })();
    </script></body></html>
    """

    static let showTestViewTool = Tool(definition: [
        "name": .string(showTestView),
        "title": "Show the test view",
        "description": """
            Show the app's test view in this conversation. It exists to test how the app draws \
            views, and does nothing else: call it only when asked to show the test view. \
            `note` is shown in the view; `seconds` holds the answer back that long, so the view \
            can be seen waiting for its result.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "note": ["type": "string", "description": "A line to show in the view."],
                "seconds": ["type": "integer", "minimum": 0, "maximum": 30,
                            "description": "How long to wait before answering. Default 0."],
            ],
        ],
        "_meta": [
            "ui": ["resourceUri": .string(testViewURI), "visibility": ["model", "app"]],
            "ui/resourceUri": .string(testViewURI),
        ],
    ])

    static let testViewCountTool = Tool(definition: [
        "name": .string(testViewCount),
        "title": "Count, for the test view",
        "description": "Add to the test view's count and say what it is. Only the view calls this.",
        "inputSchema": [
            "type": "object",
            "properties": ["by": ["type": "integer", "description": "How much to add. Default 1."]],
        ],
        "_meta": ["ui": ["resourceUri": .string(testViewURI), "visibility": ["app"]]],
    ])

    static let testView = Resource(
        uri: testViewURI, name: "test-view", title: "Test view",
        description: "The app's test view: draws, themes, resizes, counts and tries the network.",
        html: testViewHTML,
        meta: ["ui": ["prefersBorder": true]])

    /// The test view itself. No `csp` is declared, so it is drawn under the strict default
    /// and its two tries at `example.com` must both be blocked; it says so in the view and
    /// in the daemon's log, which is how a run with nobody looking proves it.
    static let testViewHTML = #"""
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Test view</title>
        <style>
        :root { color-scheme: light dark;
          --color-background-primary: light-dark(#fff, #111); --color-text-primary: light-dark(#111, #eee);
          --color-text-secondary: light-dark(#555, #aaa); --color-border-primary: light-dark(#ddd, #333);
          --color-background-tertiary: light-dark(#f2f2f2, #222); --color-text-info: light-dark(#33c, #99f);
          --color-text-danger: light-dark(#b00, #f77); --color-text-success: light-dark(#070, #7c7);
          --font-sans: system-ui, sans-serif; --font-mono: ui-monospace, monospace;
          --border-radius-sm: 6px; --border-radius-md: 10px; --font-text-sm-size: 12px; --font-text-md-size: 14px; }
        html, body { margin: 0; background: transparent; }
        body { font: var(--font-text-md-size)/1.45 var(--font-sans); color: var(--color-text-primary); }
        main { padding: 14px 16px; display: grid; gap: 10px; }
        h1 { font-size: 15px; margin: 0; font-weight: 600; }
        .row { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
        .muted { color: var(--color-text-secondary); font-size: var(--font-text-sm-size); }
        .box { background: var(--color-background-tertiary); border-radius: var(--border-radius-sm); padding: 8px 10px; }
        code { font-family: var(--font-mono); font-size: 12px; }
        button { font: inherit; font-size: 13px; color: var(--color-text-primary); background: var(--color-background-primary);
          border: 1px solid var(--color-border-primary); border-radius: var(--border-radius-sm); padding: 4px 10px; cursor: pointer; }
        .blocked { color: var(--color-text-success); } .reached { color: var(--color-text-danger); }
        #more { display: none; } body.tall #more { display: block; }
        </style></head>
        <body><main>
          <div class="row"><h1>Test view</h1><span id="state" class="muted">Waiting for the host…</span></div>
          <div id="note" class="box">No input yet.</div>
          <div class="row">
            <button id="count" type="button">Count</button><span id="counted" class="muted">Not counted yet.</span>
          </div>
          <div class="row muted"><span>Network:</span><span id="network">not tried yet</span></div>
          <div class="row muted"><span>Host:</span><span id="host">—</span></div>
          <div class="row">
            <button id="grow" type="button">Taller</button>
            <button id="mode" type="button">Fullscreen</button>
            <button id="message" type="button">Ask the agent</button>
            <button id="context" type="button">Give context</button>
            <button id="link" type="button">Open the spec</button>
          </div>
          <div id="more" class="box">More room: the view asked to be taller, and the host made it so.</div>
        </main>
        <script>
        (() => {
          let nextID = 1, mode = "inline", context = {};
          const waiting = new Map();
          const $ = (id) => document.getElementById(id);
          const post = (message) => window.parent.postMessage(Object.assign({ jsonrpc: "2.0" }, message), "*");
          const request = (method, params) => new Promise((resolve, reject) => {
            const id = nextID++; waiting.set(id, { resolve, reject }); post({ id, method, params });
          });
          const notify = (method, params) => post({ method, params });
          const log = (data, level) => notify("notifications/message", { level: level || "info", logger: "test-view", data });
          const apply = (ctx) => {
            context = Object.assign(context, ctx || {});
            const vars = (context.styles && context.styles.variables) || {};
            for (const [key, value] of Object.entries(vars)) if (value) document.documentElement.style.setProperty(key, value);
            if (context.theme) document.documentElement.style.colorScheme = context.theme;
            if (context.displayMode) { mode = context.displayMode; $("mode").textContent = mode === "fullscreen" ? "Inline" : "Fullscreen"; }
            const d = context.containerDimensions || {};
            $("host").textContent = [context.platform, context.theme, mode, d.width ? `${Math.round(d.width)} wide` : "",
              context.locale, context.timeZone].filter(Boolean).join(" · ");
          };
          const size = () => {
            const box = document.querySelector("main").getBoundingClientRect();
            notify("ui/notifications/size-changed", { width: Math.ceil(box.width), height: Math.ceil(box.height) });
          };
          window.addEventListener("message", (event) => {
            const m = event.data;
            if (!m || m.jsonrpc !== "2.0") return;
            if (m.id !== undefined && !m.method && waiting.has(m.id)) {
              const w = waiting.get(m.id); waiting.delete(m.id);
              return m.error ? w.reject(new Error(m.error.message)) : w.resolve(m.result);
            }
            switch (m.method) {
              case "ui/notifications/tool-input":
                $("note").textContent = (m.params.arguments && m.params.arguments.note) || "Called with no note.";
                $("state").textContent = "Called; waiting for the result…"; break;
              case "ui/notifications/tool-result": {
                const s = m.params.structuredContent || {};
                $("state").textContent = `Answered${s.answeredAt ? " at " + new Date(s.answeredAt).toLocaleTimeString() : ""}.`;
                break; }
              case "ui/notifications/tool-cancelled":
                $("state").textContent = `Cancelled: ${m.params.reason || "no reason given"}`; break;
              case "ui/notifications/host-context-changed":
                apply(m.params); size(); break;
              case "ui/resource-teardown":
                log("teardown: " + ((m.params && m.params.reason) || "no reason"));
                post({ id: m.id, result: {} }); break;
              case "ping":
                post({ id: m.id, result: {} }); break;
            }
          });
          const tryNetwork = async () => {
            const results = [];
            try { await fetch("https://example.com/", { mode: "no-cors", cache: "no-store" }); results.push("fetch reached"); }
            catch (e) { results.push("fetch blocked"); }
            await new Promise((resolve) => {
              const img = new Image();
              img.onload = () => { results.push("image reached"); resolve(); };
              img.onerror = () => { results.push("image blocked"); resolve(); };
              img.src = "https://example.com/favicon.ico?" + Date.now();
              setTimeout(() => { results.push("image timed out"); resolve(); }, 8000);
            });
            const blocked = results.every((r) => !r.includes("reached"));
            $("network").textContent = blocked ? "example.com blocked, as it was never declared" : results.join(", ");
            $("network").className = blocked ? "blocked" : "reached";
            log(`undeclared domain on ${context.platform || "?"}: ${results.join(", ")}`, blocked ? "info" : "error");
          };
          $("count").onclick = async () => {
            try {
              const result = await request("tools/call", { name: "test_view_count", arguments: { by: 1 } });
              const n = result.structuredContent && result.structuredContent.count;
              $("counted").textContent = `Count is ${n}.`;
              log(`count ${n}`);
            } catch (e) { $("counted").textContent = "Refused: " + e.message; }
          };
          $("grow").onclick = () => { document.body.classList.toggle("tall"); $("grow").textContent = document.body.classList.contains("tall") ? "Shorter" : "Taller"; };
          $("mode").onclick = async () => {
            const want = mode === "fullscreen" ? "inline" : "fullscreen";
            try { const r = await request("ui/request-display-mode", { mode: want }); apply({ displayMode: r.mode }); } catch (e) {}
          };
          $("message").onclick = () => request("ui/message", { role: "user", content: [{ type: "text", text: "The test view says hello. Say hello back, in a word." }] })
            .catch((e) => log("message refused: " + e.message, "warning"));
          $("context").onclick = () => request("ui/update-model-context", {
            content: [{ type: "text", text: `The test view's count is ${$("counted").textContent}` }] })
            .then(() => log("context given")).catch((e) => log("context refused: " + e.message, "warning"));
          $("link").onclick = () => request("ui/open-link", { url: "https://modelcontextprotocol.io/" }).catch(() => {});
          new ResizeObserver(size).observe(document.querySelector("main"));
          request("ui/initialize", {
            protocolVersion: "2026-01-26", clientInfo: { name: "agents-test-view", version: "1.0.0" },
            appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] },
          }).then((result) => {
            apply(result.hostContext);
            notify("ui/notifications/initialized", {});
            $("state").textContent = "Initialized; waiting for the input…";
            size();
            tryNetwork();
          }).catch((e) => { $("state").textContent = "The host refused: " + e.message; });
        })();
        </script>
        </body></html>
        """#
}
