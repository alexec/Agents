// What was exchanged: a file attached to a prompt, or one an agent handed back
// (Artifact.swift, #258). A tool call that merely touched a file is not one. That
// belongs to Files, and putting it in both would say the same thing twice.
import type { ContentBlock, TranscriptEntry, WireDate } from "../protocol/generated";

export interface Artifact {
  id: string;
  uri: string;
  name: string;
  mimeType?: string | undefined;
  size?: number | undefined;
  /** Seconds since 2001, as the entry carries it. Newest sorts first. */
  arrivedAt: WireDate;
  entryID: string;
  embedded: boolean;
  text?: string | undefined;
}

export type Destination =
  | { kind: "file"; path: string }
  | { kind: "web"; href: string }
  | { kind: "inPlace" }
  | { kind: "nowhere" };

function forTheUser(block: ContentBlock): boolean {
  const annotations = "annotations" in block ? block.annotations : undefined;
  // No audience means it is for the person. An empty one names nobody.
  if (!annotations?.audience) return true;
  return annotations.audience.includes("user");
}

function blocksOf(entry: TranscriptEntry): ContentBlock[] | null {
  const kind = entry.kind;
  if ("userMessage" in kind) return kind.userMessage.blocks?.length ? kind.userMessage.blocks : null;
  if ("agentMessage" in kind) return kind.agentMessage.blocks?.length ? kind.agentMessage.blocks : null;
  if ("compaction" in kind) return kind.compaction.summary;
  return null;
}

function lastComponent(uri: string): string {
  try {
    const name = decodeURIComponent(new URL(uri).pathname).split("/").filter(Boolean).pop();
    return name || uri;
  } catch {
    return uri.split("/").filter(Boolean).pop() || uri;
  }
}

function decodedLength(base64: string): number {
  const pad = base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor((base64.length * 3) / 4) - pad);
}

/** Everything exchanged in these entries, newest first. Derived, never stored. */
export function artifactsIn(entries: readonly TranscriptEntry[]): Artifact[] {
  const found: Artifact[] = [];
  for (const entry of entries) {
    const blocks = blocksOf(entry);
    if (!blocks) continue;
    blocks.forEach((block, index) => {
      if (!forTheUser(block)) return;
      const id = `${entry.id}:${index}`;
      if (block.type === "resource_link") {
        found.push({
          id, uri: block.uri, name: block.name, mimeType: block.mimeType, size: block.size,
          arrivedAt: entry.at, entryID: entry.id, embedded: false,
        });
      } else if (block.type === "resource") {
        const resource = block.resource;
        const size = resource.blob !== undefined ? decodedLength(resource.blob)
          : resource.text !== undefined ? new TextEncoder().encode(resource.text).length : undefined;
        found.push({
          id, uri: resource.uri, name: lastComponent(resource.uri), mimeType: resource.mimeType, size,
          arrivedAt: entry.at, entryID: entry.id, embedded: true, text: resource.text,
        });
      }
    });
  }
  return found
    .map((artifact, order) => ({ artifact, order }))
    .sort((a, b) => b.artifact.arrivedAt - a.artifact.arrivedAt || a.order - b.order)
    .map((item) => item.artifact);
}

/** Where it opens: Files, a link, in place, or nowhere. */
export function destinationOf(artifact: Artifact): Destination {
  if (artifact.embedded && artifact.text !== undefined) return { kind: "inPlace" };
  let url: URL;
  try {
    url = new URL(artifact.uri);
  } catch {
    return { kind: "nowhere" };
  }
  const scheme = url.protocol.replace(/:$/, "").toLowerCase();
  if (scheme === "file") {
    let path: string;
    try {
      path = decodeURIComponent(url.pathname);
    } catch {
      return { kind: "nowhere" };
    }
    return path.startsWith("/") ? { kind: "file", path } : { kind: "nowhere" };
  }
  if (scheme === "http" || scheme === "https") return { kind: "web", href: url.href };
  return { kind: "nowhere" };
}

/** Whether `path` is inside one of the agent's folders, so the host can read it. */
export function insideScope(path: string, roots: readonly string[]): boolean {
  return roots.some((root) => {
    const base = root.replace(/\/+$/, "") || "/";
    return base === "/" ? path.startsWith("/") : path === base || path.startsWith(base + "/");
  });
}

/**
 * Whether a listing shows the file is gone. A folder that could not be read, or one
 * that was cut short and does not contain the name, is not called gone: the record
 * stays, and only a complete listing that lacks the name says it is no longer there.
 */
export function missingInListing(listing: { entries: readonly { name: string }[]; omitted: number } | null, name: string): boolean {
  if (!listing || listing.omitted > 0) return false;
  return !listing.entries.some((entry) => entry.name === name);
}

/** "1.2 MB", in thousands, as a file size is said. */
export function bytesInWords(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "";
  if (bytes < 1000) return bytes === 1 ? "1 byte" : `${Math.round(bytes)} bytes`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1000;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  const shown = value >= 10 || Number.isInteger(value) ? String(Math.round(value)) : String(Math.round(value * 10) / 10);
  return `${shown} ${units[unit]}`;
}
