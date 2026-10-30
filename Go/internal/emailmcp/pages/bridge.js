// The MCP Apps bridge (SEP-1865) every page speaks: postMessage to the host, nothing else.
// bridge(name, on) answers the host, and gives the page its helpers. on.input, on.result
// and on.cancelled are the tool's notifications.
const bridge = (name, on) => {
  let nextID = 1;
  const waiting = new Map();
  const $ = (id) => document.getElementById(id);
  const post = (message) => window.parent.postMessage(Object.assign({ jsonrpc: "2.0" }, message), "*");
  const request = (method, params) => new Promise((resolve, reject) => {
    const id = nextID++; waiting.set(id, { resolve, reject }); post({ id, method, params });
  });
  const notify = (method, params) => post({ method, params });
  const log = (data, level) => notify("notifications/message", { level: level || "info", logger: name, data });
  const el = (tag, props, children) => {
    const node = Object.assign(document.createElement(tag), props || {});
    for (const child of children || []) if (child !== null && child !== undefined && child !== false) node.append(child);
    return node;
  };
  const openLink = (url) => request("ui/open-link", { url }).catch((e) => log("open-link refused: " + e.message, "warning"));
  const link = (text, url, props) => {
    const a = el("a", Object.assign({ textContent: text, href: url }, props || {}));
    a.onclick = (event) => { event.preventDefault(); openLink(url); };
    return a;
  };
  const button = (text, onclick, props) => {
    const b = el("button", Object.assign({ type: "button", textContent: text }, props || {}));
    b.onclick = onclick;
    return b;
  };
  const errorText = (result) => ((result && result.content) || []).map((c) => c.text || "").join("\n") || "it failed";
  // A tool's data: its structuredContent, or its text read as JSON.
  const data = (result) => {
    if (!result || result.isError) return null;
    if (result.structuredContent) return result.structuredContent;
    try { return JSON.parse(result.content[0].text); } catch (e) { return null; }
  };
  const call = async (tool, args) => {
    const result = await request("tools/call", { name: tool, arguments: args });
    if (!result || result.isError) throw new Error(errorText(result));
    return data(result) || result;
  };
  const ago = (time) => {
    const minutes = Math.max(0, Math.round((Date.now() - Date.parse(time)) / 60000));
    if (!Number.isFinite(minutes)) return "";
    if (minutes < 60) return minutes + "m ago";
    if (minutes < 48 * 60) return Math.round(minutes / 60) + "h ago";
    return Math.round(minutes / 1440) + "d ago";
  };
  const apply = (ctx) => {
    const vars = (ctx && ctx.styles && ctx.styles.variables) || {};
    for (const [key, value] of Object.entries(vars)) if (value) document.documentElement.style.setProperty(key, value);
    if (ctx && ctx.theme) document.documentElement.style.colorScheme = ctx.theme;
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
      return m.error ? w.reject(Object.assign(new Error(m.error.message), { code: m.error.code })) : w.resolve(m.result);
    }
    switch (m.method) {
      case "ui/notifications/tool-input":
        on.input((m.params && m.params.arguments) || {}); break;
      case "ui/notifications/tool-result":
        on.result(m.params); break;
      case "ui/notifications/tool-cancelled":
        on.cancelled((m.params && m.params.reason) || "no reason given"); break;
      case "ui/notifications/host-context-changed":
        apply(m.params); size(); break;
      case "ui/resource-teardown":
      case "ping":
        post({ id: m.id, result: {} }); break;
    }
  });
  // The lists' sections for a team (#2453): each row's section, from the server, in this
  // order, a heading over each that has rows. Rows from a server without sections: no headings.
  const SECTIONS = [["needs_you", "Needs you"], ["yours", "Yours"], ["team", "Team"], ["others", "Others"]];
  const sections = (items, row) => {
    if (!items.some((item) => item.section)) return items.map(row);
    return SECTIONS.flatMap(([key, title]) => {
      const rows = items.filter((item) => (item.section || "others") === key);
      if (!rows.length) return [];
      const head = el("li", { className: "section " + key }, [el("span", { textContent: title }), el("span", { className: "muted", textContent: String(rows.length) })]);
      head.setAttribute("role", "heading"); head.setAttribute("aria-level", "2");
      return [head, ...rows.map(row)];
    });
  };
  // Who opened it, with a bot pill for a bot.
  const who = (login, bot) => [el("span", { textContent: login || "someone" }),
    bot ? el("span", { className: "pill bot", textContent: "bot", title: login + " is a bot" }) : null];
  const ui = { $, request, notify, log, el, link, openLink, button, errorText, data, call, ago, size, sections, who };
  ui.start = (waitingWords) => {
    new ResizeObserver(size).observe(document.querySelector("main"));
    request("ui/initialize", {
      protocolVersion: "2026-01-26", clientInfo: { name, version: "0.1.0" },
      appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] },
    }).then((result) => {
      apply(result && result.hostContext);
      notify("ui/notifications/initialized", {});
      on.started && on.started(waitingWords);
      size();
    }).catch((e) => on.cancelled("the host refused: " + e.message));
  };
  return ui;
};
