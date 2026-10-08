// Open File… (#415), as the window's FileSearch: a field over the page that finds a file in the
// session's folders by name and path as it is typed (the host's files/mention, the @ search),
// and opens the one chosen. Up and Down move, Return opens, Escape or a click outside closes it
// and changes nothing.
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { FileMentionDTO } from "../../protocol/generated";
import { nameOf } from "./paneState";

const pause = 120;

export function FileSearch({ place, search, choose, close }: {
  place: string;
  search: (term: string) => Promise<FileMentionDTO[]>;
  choose: (file: FileMentionDTO) => void;
  close: () => void;
}) {
  const term = useSignal("");
  const found = useSignal<FileMentionDTO[]>([]);
  const searched = useSignal(false);
  const selected = useSignal(0);
  const asking = useRef(0);
  const field = useRef<HTMLInputElement>(null);

  useEffect(() => { field.current?.focus(); }, []);

  useEffect(() => {
    const asked = term.value.trim();
    const turn = ++asking.current;
    if (!asked) {
      found.value = [];
      searched.value = false;
      return;
    }
    const timer = setTimeout(() => {
      void search(asked).then((answer) => {
        if (asking.current !== turn) return;
        found.value = answer;
        selected.value = 0;
        searched.value = true;
      });
    }, pause);
    return () => clearTimeout(timer);
  }, [term.value]);

  return (
    <div class="file-search-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) close(); }}>
      <div class="file-search" role="dialog" aria-label="Open File">
        <input ref={field} type="search" placeholder={`Open a file in ${place}`} aria-label="Open a file"
          autocomplete="off" spellcheck={false} value={term.value}
          onInput={(e) => (term.value = (e.currentTarget as HTMLInputElement).value)}
          onKeyDown={(e) => {
            if (e.key === "Escape") { e.preventDefault(); close(); }
            else if (e.key === "ArrowDown" && found.value.length) { e.preventDefault(); selected.value = Math.min(selected.value + 1, found.value.length - 1); }
            else if (e.key === "ArrowUp" && found.value.length) { e.preventDefault(); selected.value = Math.max(selected.value - 1, 0); }
            else if (e.key === "Enter") {
              e.preventDefault();
              const chosen = found.value[selected.value];
              if (chosen) choose(chosen);
            }
          }} />
        {found.value.length > 0 && (
          <ul class="completions" role="listbox" aria-label="Files">
            {found.value.map((m, i) => (
              <li key={m.path} role="option" aria-selected={i === selected.value} class={i === selected.value ? "chosen" : ""}
                ref={(el) => { if (el && i === selected.value) el.scrollIntoView({ block: "nearest" }); }}
                onMouseDown={(e) => { e.preventDefault(); choose(m); }}>
                <span>{nameOf(m.path)}</span>
                <span class="quiet small">{m.relativePath}</span>
              </li>
            ))}
          </ul>
        )}
        {found.value.length === 0 && searched.value && term.value.trim() && (
          <p class="hint">No files match “{term.value.trim()}”.</p>
        )}
      </div>
    </div>
  );
}

/** ⌘P on a Mac, Ctrl+P elsewhere: Open File… rather than the browser's Print. */
export function isOpenFileKey(e: KeyboardEvent): boolean {
  return (e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && e.key.toLowerCase() === "p";
}
