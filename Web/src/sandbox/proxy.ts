// The sandbox proxy (#187, MCP Apps SEP-1865 "Sandbox proxy"): the web page's view host draws
// each view through this page, which the control plane serves only at the loopback address,
// 127.0.0.1, a different origin from the page's own at localhost on the same port, framed only by that page and
// under the view's own policy (LoopbackGate). It holds the view in an inner
// <iframe sandbox="allow-scripts"> (an opaque origin: nothing of this page's or the app's to
// read) and carries messages both ways, except the spec's own sandbox-* ones, which it keeps.
import { header, withPolicy, type Domains } from "./policy";

const host = `http://localhost:${location.port}`;
let view: HTMLIFrameElement | null = null;

type Message = { jsonrpc?: unknown; method?: unknown; params?: { html?: unknown; csp?: Domains } };
const isSandboxMessage = (m: Message) => typeof m?.method === "string" && m.method.startsWith("ui/notifications/sandbox-");

function load(html: string, csp: Domains | undefined): void {
  if (view) return; // One view a proxy, once.
  view = document.createElement("iframe");
  view.setAttribute("sandbox", "allow-scripts");
  view.setAttribute("referrerpolicy", "no-referrer");
  view.title = "View";
  Object.assign(view.style, { display: "block", border: "0", width: "100%", height: "100vh", background: "transparent" });
  view.srcdoc = withPolicy(html, header(csp));
  document.body.append(view);
}

window.addEventListener("message", (event) => {
  const message = event.data as Message;
  if (event.source === window.parent && event.origin === host) {
    if (message?.method === "ui/notifications/sandbox-resource-ready") {
      if (typeof message.params?.html === "string") load(message.params.html, message.params.csp);
      return;
    }
    if (isSandboxMessage(message)) return;
    view?.contentWindow?.postMessage(message, "*");
  } else if (view && event.source === view.contentWindow) {
    if (isSandboxMessage(message)) return;
    window.parent.postMessage(message, host);
  }
});

Object.assign(document.documentElement.style, { margin: "0", padding: "0", overflow: "hidden", background: "transparent" });
window.parent.postMessage({ jsonrpc: "2.0", method: "ui/notifications/sandbox-proxy-ready", params: {} }, host);
