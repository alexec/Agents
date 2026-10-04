// The Content-Security-Policy a view is drawn under (#187), from the domains its server declared
// and the control plane allowed: the same string AgentsKitCore's AppViewPolicy.header writes, so
// the sandbox proxy's own response and the <meta> it puts at the top of the view say one thing.
// test/appViews.test.mjs holds the two to the same strings.

export interface Domains {
  connectDomains?: string[];
  resourceDomains?: string[];
  frameDomains?: string[];
  baseUriDomains?: string[];
}

/** A plain origin, as AppViewPolicy.origin keeps one; anything else is dropped. */
export function origin(text: string): string | null {
  const value = text.trim().toLowerCase();
  const scheme = ["https://", "wss://", "http://", "ws://"].find((s) => value.startsWith(s));
  if (!scheme) return null;
  let rest = value.slice(scheme.length);
  if (rest.endsWith("/")) rest = rest.slice(0, -1);
  let host = rest;
  const colon = rest.lastIndexOf(":");
  if (colon >= 0) {
    const port = rest.slice(colon + 1);
    if (!/^[0-9]+$/.test(port) || Number(port) < 1 || Number(port) > 65535) return null;
    host = rest.slice(0, colon);
  }
  if (host.startsWith("*.")) host = host.slice(2);
  if (!host || host.length > 253) return null;
  const ok = host.split(".").every((label) => /^[a-z0-9-]{1,63}$/.test(label) && !label.startsWith("-") && !label.endsWith("-"));
  return ok ? scheme + rest : null;
}

const kept = (list: unknown): string[] =>
  Array.isArray(list) ? [...new Set(list.flatMap((v) => (typeof v === "string" && origin(v) ? [origin(v)!] : [])))] : [];

export function narrowed(domains: Domains | undefined): Required<Domains> {
  return {
    connectDomains: kept(domains?.connectDomains),
    resourceDomains: kept(domains?.resourceDomains),
    frameDomains: kept(domains?.frameDomains),
    baseUriDomains: kept(domains?.baseUriDomains),
  };
}

export function header(domains: Domains | undefined): string {
  const d = narrowed(domains);
  const list = (base: string[], extra: string[], none = false) => {
    const all = [...base, ...extra];
    return all.length ? all.join(" ") : none ? "'none'" : "";
  };
  const resource = d.resourceDomains;
  return [
    "default-src 'none'",
    `script-src ${list(["'self'", "'unsafe-inline'"], resource)}`,
    `style-src ${list(["'self'", "'unsafe-inline'"], resource)}`,
    `img-src ${list(["'self'", "data:", "blob:"], resource)}`,
    `font-src ${list(["'self'", "data:"], resource)}`,
    `media-src ${list(["'self'", "data:", "blob:"], resource)}`,
    `connect-src ${list([], d.connectDomains, true)}`,
    `frame-src ${list([], d.frameDomains, true)}`,
    "object-src 'none'",
    `base-uri ${list(["'self'"], d.baseUriDomains)}`,
    "form-action 'none'",
  ].join("; ");
}

const escapeAttribute = (text: string) =>
  text.replaceAll("&", "&amp;").replaceAll("\"", "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

/** The view's HTML with the policy first in its <head> (AppViewShell.withPolicy). */
export function withPolicy(html: string, policy: string): string {
  const meta = `<meta http-equiv="Content-Security-Policy" content="${escapeAttribute(policy)}">`;
  const head = /<head[^>]*>/i.exec(html);
  if (head) return html.slice(0, head.index + head[0].length) + meta + html.slice(head.index + head[0].length);
  const open = /<html[^>]*>/i.exec(html);
  if (open) return html.slice(0, open.index + open[0].length) + `<head>${meta}</head>` + html.slice(open.index + open[0].length);
  return `<head>${meta}</head>` + html;
}

/** The query the proxy is loaded with: its domains, so the control plane can build its policy. */
export function encodeDomains(domains: Domains): string {
  const json = JSON.stringify(narrowed(domains));
  const bytes = new TextEncoder().encode(json);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}
