import AgentsKitCore
import Foundation

/// The views the app's own `agents` server serves (#187, MCP Apps): each `ui://` resource,
/// and the tools that draw one or that only a view may call.
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
        /// Marked as changing nothing (`annotations.readOnlyHint`).
        public var readOnly: Bool { definition["annotations"]?["readOnlyHint"]?.boolValue == true }
        /// Whether opening a pin may call it (#189): a view may call it, and it changes
        /// nothing, because a pin calls it every time it opens.
        public var feedsPins: Bool { forApp && readOnly }
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

    /// Every tool with a view or for a view, as offered now.
    public static func tools(testView: Bool = offersTestView) -> [Tool] {
        testView ? [showTestViewTool, testViewCountTool] : []
    }

    /// Every resource, as offered now.
    public static func resources(testView: Bool = offersTestView) -> [Resource] {
        testView ? [Self.testView] : []
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

    // MARK: Pins (#189)

    /// Why `view` can't be pinned, in words for whoever asked, or nil when it can. Until
    /// third-party views (#191), only the app's own server's.
    public static func pinRefusal(_ view: ViewPin, testView: Bool = offersTestView) -> String? {
        if let problem = PinRules.problem(view) { return problem }
        guard view.server == AppTool.serverName else {
            return "only the \(AppTool.serverName) server's views can be pinned so far, not \(view.server)'s."
        }
        guard resource(view.uri, testView: testView) != nil else { return "the \(view.server) server has no view at \(view.uri)." }
        guard let tool = tools(testView: testView).first(where: { $0.name == view.tool }), tool.resourceURI == view.uri else {
            return "\(view.tool) does not feed \(view.uri)."
        }
        guard tool.feedsPins else {
            return "\(view.tool) can't feed a pin: only a tool a view may call and that changes nothing "
                + "(readOnlyHint) can, since opening the pin calls it."
        }
        return nil
    }

    /// Why a pinned view can't be drawn on this host (`PinMissing`), or nil when it can.
    public static func missingReason(_ view: ViewPin, testView: Bool = offersTestView) -> String? {
        guard view.server == AppTool.serverName else { return PinMissing.serverNotSetUp }
        guard resource(view.uri, testView: testView) != nil,
              tools(testView: testView).contains(where: { $0.name == view.tool && $0.resourceURI == view.uri && $0.feedsPins })
        else { return PinMissing.noSuchView }
        return nil
    }

    /// Whether a call of `tool` drawing `uri` could be pinned, for the Pin in a view's menu.
    public static func pinnable(tool: String, uri: String, testView: Bool = offersTestView) -> Bool {
        pinRefusal(ViewPin(server: AppTool.serverName, uri: uri, tool: tool), testView: testView) == nil
    }

    // MARK: The test view

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
        "annotations": ["readOnlyHint": true],
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
