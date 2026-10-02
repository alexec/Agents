// A Git URL the host can clone (027): GitRemote (AgentsKitCore/Model/GitRemote.swift), ported by
// hand for Clone Git URL… (#115). Only what the sheet says: is it one, and what folder it becomes.
// The host checks it again before it clones.

export interface GitRemote {
  /** Exactly what was given, trimmed. This is what is handed to git. */
  url: string;
  /** Lowercased, without a user or a port. */
  host: string;
  /** As written, without leading or trailing slashes. */
  path: string;
  /** The folder it becomes: the last part of the path without `.git`, case kept. */
  folderName: string;
}

export function gitRemote(text: string): GitRemote | null {
  const trimmed = text.trim();
  // Nothing git would read as an option, and nothing that needs quoting.
  if (!trimmed || trimmed.startsWith("-") || /\s/.test(trimmed)) return null;

  let host: string;
  let path: string;
  if (trimmed.includes("://")) {
    let url: URL;
    try {
      url = new URL(trimmed);
    } catch {
      return null;
    }
    const scheme = url.protocol.slice(0, -1).toLowerCase();
    if ((scheme !== "https" && scheme !== "ssh") || !url.hostname) return null;
    host = url.hostname;
    path = decodeURIComponent(url.pathname);
  } else {
    // `[user@]host:path`. Git reads it this way only when no slash comes before the colon,
    // which is also what keeps `./a:b` a path.
    const colon = trimmed.indexOf(":");
    if (colon < 0) return null;
    const before = trimmed.slice(0, colon);
    if (before.includes("/")) return null;
    const named = before.split("@").pop() ?? "";
    if (!named) return null;
    host = named;
    path = trimmed.slice(colon + 1);
  }

  const cleanPath = path.replace(/^\/+|\/+$/g, "");
  if (!cleanPath) return null;
  const last = cleanPath.split("/").filter(Boolean).pop() ?? "";
  const folderName = last.endsWith(".git") ? last.slice(0, -4) : last;
  if (!folderName || folderName === "." || folderName === "..") return null;
  return { url: trimmed, host: host.toLowerCase(), path: cleanPath, folderName };
}
