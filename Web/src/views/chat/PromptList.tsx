// The Prompts list (#1658), from the chat's ··· menu: each prompt the person sent in this chat,
// oldest first and opened at the newest, with its turn's cost, time and ending. A filter field
// narrows it. A row goes to its prompt in the transcript; its ··· has Copy and Branch from Here.
// Up and Down move, Return goes, Escape or a click outside closes it. Rows are numbered from the
// chat's first prompt, as the host counts them; while earlier turns are not in hand, a line above
// the rows says so and loads them (#1862).
import { useSignal } from "@preact/signals";
import { hostNeedsUpdate } from "../../model/capabilities";
import { useEffect, useRef } from "preact/hooks";
import { endingLabel, filteredPrompts, movedTo, promptLine, type SessionPrompt } from "../../model/sessionPrompts";

export function PromptList({ prompts, hasEarlier, loadEarlier, choose, branchFrom, branchNeedsUpdate = false, close }: {
  prompts: readonly SessionPrompt[];
  /** Earlier turns of the chat are not in hand. */
  hasEarlier: boolean;
  /** Brings the page before them; absent when the chat holds all it will (#291). */
  loadEarlier?: (() => Promise<void>) | undefined;
  choose: (prompt: SessionPrompt) => void;
  /** Absent on an archived session, as Branch is. */
  branchFrom?: ((prompt: SessionPrompt) => void) | undefined;
  /** The host is too old to branch: Branch from Here greyed, saying so (#1866). */
  branchNeedsUpdate?: boolean;
  close: () => void;
}) {
  const query = useSignal("");
  const loading = useSignal(false);
  const field = useRef<HTMLInputElement>(null);
  useEffect(() => { field.current?.focus(); }, []);
  const shown = filteredPrompts(prompts, query.value);
  /** The chosen row: the newest until Up or Down moves it. */
  const at = useSignal<number | null>(null);
  const chosen = at.value === null || at.value >= shown.length ? shown.length - 1 : at.value;
  /** The row whose ··· menu is open, and where: over the list, which would clip it, so placed on the page. */
  const menu = useSignal<string | null>(null);
  const menuAt = useSignal<{ top: number; right: number }>({ top: 0, right: 0 });
  const now = new Date();

  const go = (prompt: SessionPrompt | undefined) => {
    if (!prompt) return;
    close();
    choose(prompt);
  };

  return (
    <div class="file-search-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) close(); }}>
      {/* Keys from the field and from a row's ···, so Escape closes an open ··· first, then the list. */}
      <div class="file-search prompt-list" role="dialog" aria-label="Prompts" onKeyDown={(e) => {
        if (e.key === "Escape") {
          e.preventDefault();
          if (menu.value) {
            menu.value = null;
            field.current?.focus();
          } else close();
        } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
          e.preventDefault();
          menu.value = null;
          at.value = movedTo(chosen < 0 ? null : chosen, shown.length, e.key === "ArrowDown");
          field.current?.focus();
        } else if (e.key === "Enter" && e.target === field.current) {
          e.preventDefault();
          go(shown[chosen]);
        }
      }}>
        <h2>Prompts</h2>
        <input ref={field} type="search" placeholder="Filter prompts" aria-label="Filter prompts"
          autocomplete="off" spellcheck={false} value={query.value}
          aria-controls="prompt-list-rows" aria-activedescendant={shown[chosen] ? `prompt-${shown[chosen].id}` : undefined}
          onInput={(e) => {
            query.value = (e.currentTarget as HTMLInputElement).value;
            at.value = null;
            menu.value = null;
          }} />
        {hasEarlier && (
          <p class="prompt-earlier quiet small" role="status">
            <span>Earlier prompts aren't loaded</span>
            {loadEarlier && (
              <button class="link" disabled={loading.value} onClick={() => {
                loading.value = true;
                void loadEarlier().finally(() => (loading.value = false));
              }}>{loading.value ? "Loading…" : "Load Earlier"}</button>
            )}
          </p>
        )}
        {shown.length > 0 ? (
          <ul class="completions" id="prompt-list-rows" role="listbox" aria-label="Prompts" onScroll={() => (menu.value = null)}>
            {shown.map((prompt, i) => (
              <li key={prompt.id} id={`prompt-${prompt.id}`} role="option" aria-selected={i === chosen} class={i === chosen ? "chosen" : ""}
                ref={(el) => { if (el && i === chosen) el.scrollIntoView({ block: "nearest" }); }}
                onMouseDown={(e) => {
                  if ((e.target as HTMLElement).closest(".prompt-row-menu")) return;
                  e.preventDefault();
                  go(prompt);
                }}>
                <span class="prompt-number faint">{prompt.number}</span>
                <span class="prompt-words">
                  <span class="prompt-title">{prompt.title}</span>
                  <span class="quiet small">{promptLine(prompt, now)}</span>
                </span>
                {prompt.ending && (
                  <span class={`prompt-ending ${prompt.ending}`} role="img" aria-label={endingLabel(prompt.ending)} title={endingLabel(prompt.ending)}>
                    {prompt.ending === "stopped" ? "■" : "!"}
                  </span>
                )}
                <RowMenu open={menu.value === prompt.id} at={menuAt.value}
                  toggle={(button) => {
                    const box = button.getBoundingClientRect();
                    menuAt.value = { top: box.bottom + 4, right: window.innerWidth - box.right };
                    menu.value = menu.value === prompt.id ? null : prompt.id;
                  }}
                  copy={() => {
                    menu.value = null;
                    void navigator.clipboard?.writeText(prompt.text).catch(() => {});
                  }}
                  branch={branchFrom && (() => {
                    menu.value = null;
                    close();
                    branchFrom(prompt);
                  })} branchNeedsUpdate={branchNeedsUpdate} number={prompt.number} />
              </li>
            ))}
          </ul>
        ) : (prompts.length > 0 || !hasEarlier) && (
          // None in hand while earlier ones are not loaded: the line above says so.
          <p class="hint">{prompts.length ? "No prompts match" : "No prompts yet"}</p>
        )}
      </div>
    </div>
  );
}

/** A row's ···: Copy, and Branch from Here where the session can branch. */
function RowMenu({ open, at, toggle, copy, branch, branchNeedsUpdate, number }: {
  open: boolean; at: { top: number; right: number }; toggle: (button: HTMLElement) => void; copy: () => void;
  branch: (() => void) | undefined; branchNeedsUpdate: boolean; number: number;
}) {
  return (
    <span class="menu-anchor prompt-row-menu">
      <button class="icon" aria-label={`More for prompt ${number}`} title="More" aria-haspopup="menu" aria-expanded={open}
        onClick={(e) => toggle(e.currentTarget)}>···</button>
      {open && (
        <div class="popover right" role="menu" style={{ position: "fixed", top: `${at.top}px`, right: `${at.right}px`, left: "auto" }}>
          <button role="menuitem" title="Copy the whole prompt" onClick={copy}>Copy</button>
          {branch && (
            <button role="menuitem" title="Start a new session from just before this prompt, with the prompt in its bar to change. The files stay as they are now."
              onClick={branch}>Branch from Here</button>
          )}
          {!branch && branchNeedsUpdate && <button role="menuitem" title={hostNeedsUpdate} disabled>Branch from Here</button>}
        </div>
      )}
    </span>
  );
}
