// Where a relative link on a Markdown page goes (#5068), as `MarkdownLink` on the Mac and the
// Remote (#5067): read against the page's own file, `other.md` and `../docs/a.md` name the file
// beside the page, and a link to only a `#fragment` stays on the page.

/** A file by its path, beside the page's own; or only a part of the page itself. */
export type PageLink = { kind: "file"; path: string } | { kind: "samePage" };

const withScheme = /^[a-z][a-z0-9+.-]*:/i;

/**
 * Where a relative `href` goes from the page whose file is `document`, or null when it is no
 * relative link (it has a scheme, or is an absolute path) or it climbs out above the top.
 *
 * `document` is a full path (`/Users/a/p/docs/plan.md`) or a path in a folder
 * (`docs/plan.md`, a pinned page's or a folder doc's); the file comes back in the same form.
 * Any `?query` and `#fragment` is dropped.
 */
export function pageLinkTarget(href: string, document: string): PageLink | null {
  const raw = href.trim();
  if (!raw || withScheme.test(raw) || raw.startsWith("/") || /[\u0000-\u001f\\]/.test(raw)) return null;
  let path: string;
  try {
    path = decodeURIComponent(raw.split(/[?#]/, 1)[0]!);
  } catch {
    return null;
  }
  if (!path) return { kind: "samePage" };
  if (/[\u0000-\u001f\\]/.test(path)) return null;
  const absolute = document.startsWith("/");
  const folder = document.slice(0, Math.max(0, document.lastIndexOf("/")));
  const parts: string[] = [];
  for (const part of `${folder}/${path}`.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (parts.length === 0) return null;
      parts.pop();
      continue;
    }
    parts.push(part);
  }
  if (parts.length === 0) return null;
  return { kind: "file", path: (absolute ? "/" : "") + parts.join("/") };
}

/** A pinned page's kind of file: Markdown or HTML, as `PinRules.kind`. */
export function isPageFile(path: string): boolean {
  return /\.(md|markdown|mdown|mkd|html?)$/i.test(path);
}

/**
 * `path` as a path in `folder` (a full path, with or without the trailing `/`), or null when it is
 * outside it. A path that is already in a folder (no leading `/`) is kept as it is.
 */
export function pathInFolder(path: string, folder: string): string | null {
  if (!path.startsWith("/")) return path;
  const base = folder.replace(/\/+$/, "") + "/";
  return path.startsWith(base) && path.length > base.length ? path.slice(base.length) : null;
}
