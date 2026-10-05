// Which folder a watch is really of, and how many panes are holding it (#258).
//
// The host watches an agent's folder, not the subfolder a pane asked about: two panes
// watching paths inside one folder are one watch, and the first to leave must not stop
// it while the other is still looking. `files/changed` for that agent is why an open
// file is read again, as the window re-reads one on any change under the agent.

/** A file URL or a path, as an absolute path with no trailing slash. */
export function absolutePath(urlOrPath: string): string {
  if (urlOrPath.startsWith("/")) return urlOrPath.replace(/\/+$/, "") || "/";
  try {
    const path = decodeURIComponent(new URL(urlOrPath).pathname);
    return path.replace(/\/+$/, "") || "/";
  } catch {
    return urlOrPath;
  }
}

/**
 * The agent's folder that holds `folder`: the working folder, or an extra one it was
 * given, the longest match. A path in none of them is watched as itself.
 */
export function scopeRoot(cwd: string, extras: readonly string[], folder: string): string {
  const path = absolutePath(folder);
  let best: string | null = null;
  for (const root of [cwd, ...extras].map(absolutePath)) {
    const holds = root === "/" || path === root || path.startsWith(root + "/");
    if (holds && (best === null || root.length > best.length)) best = root;
  }
  return best ?? path;
}

/** How many panes hold each watch. The first asks the host; the last tells it to stop. */
export class WatchCounts {
  private counts = new Map<string, number>();

  /** True when this is the first hold, so the host should be asked. */
  watch(key: string): boolean {
    const held = this.counts.get(key) ?? 0;
    this.counts.set(key, held + 1);
    return held === 0;
  }

  /** True when this was the last hold, so the host should be told to stop. */
  unwatch(key: string): boolean {
    const held = this.counts.get(key) ?? 0;
    if (held <= 1) {
      this.counts.delete(key);
      return held === 1;
    }
    this.counts.set(key, held - 1);
    return false;
  }
}

/** An open file is read again when the host says something under that agent changed. */
export function openFileShouldReread(change: { agentID: string } | null, agentID: string): boolean {
  return change !== null && change.agentID === agentID;
}
