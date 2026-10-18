// Where this page is: the one Agents Host serves on this Mac at localhost (071), or the one on
// the control plane's own domain (#1459), which a browser anywhere opens.

/** Whether this page is the one on this Mac, at localhost. */
export function onThisMac(host: string = location.hostname): boolean {
  return host === "localhost" || host === "127.0.0.1" || host === "[::1]" || host === "::1";
}
