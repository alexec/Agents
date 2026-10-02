// What a new session may reach beyond its own folder (PromptBar's reach chip and AgentReachView):
// other folders on the same host, sent as the start's additionalDirectories. A browser can't pick
// a folder on the host, so one is typed as its path. MCP servers are chosen in the window.
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";

/** "Reach: this folder", or how many folders, as the window says it. */
export function reachTitle(folders: readonly string[]): string {
  return folders.length ? `Reach: ${folders.length + 1} folders` : "Reach: this folder";
}

/** A typed absolute path as the file URL the host takes, or null when it isn't one. */
export function folderURL(path: string): string | null {
  const trimmed = path.trim().replace(/\/+$/, "");
  if (!trimmed.startsWith("/")) return null;
  return "file://" + encodeURI(trimmed) + "/";
}

export function Reach({ folders, change, disabled }: {
  folders: string[]; change: (folders: string[]) => void; disabled: boolean;
}) {
  const open = useSignal(false);
  const typed = useSignal("");
  const said = useSignal<string | null>(null);
  const anchor = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open.value) return;
    const close = (e: Event) => { if (!anchor.current?.contains(e.target as Node)) open.value = false; };
    const escape = (e: KeyboardEvent) => { if (e.key === "Escape") open.value = false; };
    addEventListener("pointerdown", close);
    addEventListener("keydown", escape);
    return () => { removeEventListener("pointerdown", close); removeEventListener("keydown", escape); };
  }, [open.value]);

  const add = () => {
    const url = folderURL(typed.value);
    if (!url) {
      said.value = "Type the folder's full path, starting with /.";
      return;
    }
    if (!folders.includes(url)) change([...folders, url]);
    typed.value = "";
    said.value = null;
  };

  return (
    <span class="menu-anchor reach" ref={anchor}>
      <button class="pill" aria-haspopup="dialog" aria-expanded={open.value} disabled={disabled}
        title="Folders this agent may reach" onClick={() => (open.value = !open.value)}>
        {reachTitle(folders)} <span aria-hidden="true">▾</span>
      </button>
      {open.value && (
        <div class="popover up reach-popover" role="dialog" aria-label="Reach">
          <p class="small quiet">Besides its own folder, the agent may read and write in:</p>
          {folders.length > 0 && (
            <ul class="reach-folders">
              {folders.map((url) => {
                const path = decodeURI(url.replace(/^file:\/\//, "")).replace(/\/$/, "");
                return (
                  <li key={url}>
                    <span title={path}>{path}</span>
                    <button class="remove" aria-label={`Remove ${path}`} onClick={() => change(folders.filter((f) => f !== url))}>×</button>
                  </li>
                );
              })}
            </ul>
          )}
          <div class="reach-add">
            <input aria-label="Folder path" placeholder="/path/to/folder" value={typed.value}
              onInput={(e) => { typed.value = (e.currentTarget as HTMLInputElement).value; said.value = null; }}
              onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); add(); } }} />
            <button onClick={add} disabled={!typed.value.trim()}>Add</button>
          </div>
          {said.value && <p class="failure small" role="status">{said.value}</p>}
          <p class="faint small">MCP servers are chosen in the window.</p>
        </div>
      )}
    </span>
  );
}
