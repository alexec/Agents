// Where this page is: the one Agents Host serves on this Mac at localhost (071), or the one on
// the control plane's own domain (#1459), which a browser anywhere opens. And where its MCP Apps
// views' sandbox proxy is (#187): another origin than the page's, which MCP Apps needs. On this
// Mac that is the listener's address, 127.0.0.1; on the domain, a second name in front of the
// same control plane (views.<domain>, #1484), which control/status says.

/** Whether this page is the one on this Mac, at localhost. */
export function onThisMac(host: string = location.hostname): boolean {
  return host === "localhost" || host === "127.0.0.1" || host === "[::1]" || host === "::1";
}

/** What control/status said of the views' second name: its origin, null for none, undefined before it said. */
let publicViews: string | null | undefined;
const waiting: Array<(origin: string | null) => void> = [];

/** control/status's `publicViews`, once the page has it (#1484). */
export function knowPublicViews(origin: string | null | undefined): void {
  publicViews = origin ?? null;
  for (const resolve of waiting.splice(0)) resolve(publicViews);
}

/**
 * The sandbox proxy's origin: the listener's address on this Mac, or on the domain the second
 * name control/status says (waited for until it has said), or null when there is none, and so no
 * views are drawn.
 */
export function viewsOrigin(host: string = location.hostname): Promise<string | null> {
  if (onThisMac(host)) return Promise.resolve(`http://127.0.0.1:${location.port}`);
  if (publicViews !== undefined) return Promise.resolve(publicViews);
  return new Promise((resolve) => waiting.push(resolve));
}

/**
 * The page's origin, as the sandbox proxy hears it: the listener's name on this Mac (the address
 * is the proxy's), or on the domain the `host` the page gave in the proxy's own address. Only an
 * https one: the control plane frames the proxy for the page's origin and nothing else.
 */
export function pageOrigin(host: string = location.hostname, search: string = location.search): string | null {
  if (onThisMac(host)) return `http://localhost:${location.port}`;
  const given = new URLSearchParams(search).get("host");
  return given && /^https:\/\/[a-z0-9.-]+(:[0-9]+)?$/.test(given) ? given : null;
}
