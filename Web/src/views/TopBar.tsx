// The top bar's right end and the page's breadcrumb (#2142): search ("/" to it) over the pages, machines
// and sessions this page holds; the signed-in person's initial and their menu (who, their role, Settings,
// Forget This Browser, which was at the agents' list's foot); and the trail over a page's title.
import { useEffect, useRef } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { ComponentChildren } from "preact";
import type { Store } from "../model/store";
import type { Session } from "../session";
import { go, route, type Route } from "../route";
import { folderKey } from "../model/groups";
import { adminOf } from "../model/console";
import { placedSessions } from "../model/overview";
import { searchFound } from "../model/search";
import { navTitle } from "../model/nav";
import { initialOf, type Crumb } from "../model/crumbs";

/** "/" goes to the search field, when the focus is not in a field, as a web console's does. */
function useSlashKey(field: { current: HTMLInputElement | null }, open: () => void) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      if (e.key !== "/" || e.metaKey || e.ctrlKey || e.altKey || target?.closest("input, textarea, select, [contenteditable=true]")) return;
      e.preventDefault();
      open();
      requestAnimationFrame(() => field.current?.focus());
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, []);
}

export function SearchBox({ store }: { store: Store }) {
  const words = useSignal("");
  const at = useSignal(0);
  const focused = useSignal(false);
  // Below 760 the field is a button that opens it over the bar.
  const opened = useSignal(false);
  const field = useRef<HTMLInputElement>(null);
  useSlashKey(field, () => { opened.value = true; });
  const found = focused.value ? searchFound(words.value, adminOf(store), store.hosts.value,
    placedSessions(store.hosts.value, store.folders.value, (h, f) => store.folderView(h, f).headings.flatMap((x) => x.agents))) : [];
  const pick = (to: Route) => {
    go(to);
    words.value = "";
    opened.value = false;
    field.current?.blur();
  };
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "ArrowDown") { e.preventDefault(); at.value = Math.min(at.value + 1, found.length - 1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); at.value = Math.max(at.value - 1, 0); }
    else if (e.key === "Enter" && found[at.value]) { e.preventDefault(); pick(found[at.value]!.to); }
    else if (e.key === "Escape") { words.value = ""; opened.value = false; field.current?.blur(); }
  };
  return (
    <div class={`top-search${opened.value ? " opened" : ""}`} role="search">
      <button type="button" class="top-search-button narrow-only" aria-label="Search"
        onClick={() => { opened.value = true; requestAnimationFrame(() => field.current?.focus()); }}>⌕</button>
      <input ref={field} type="text" autocomplete="off" placeholder="Search or jump to…" aria-label="Search or jump to"
        role="combobox" aria-expanded={found.length > 0} aria-controls="top-search-found" aria-autocomplete="list"
        aria-activedescendant={found.length ? `found-${at.value}` : undefined} value={words.value}
        onInput={(e) => { words.value = (e.currentTarget as HTMLInputElement).value; at.value = 0; }}
        onFocus={() => { focused.value = true; }}
        // After a press on a result has gone through.
        onBlur={() => { setTimeout(() => { focused.value = false; if (!words.value) opened.value = false; }, 150); }}
        onKeyDown={onKey} />
      {!words.value && <kbd class="top-search-key" aria-hidden="true">/</kbd>}
      {focused.value && words.value.trim() && (
        <ul id="top-search-found" class="top-search-found" role="listbox" aria-label="Found">
          {found.length === 0 && <li class="none">Nothing called that.</li>}
          {found.map((f, i) => (
            <li key={`${f.kind}|${f.title}|${f.detail}`} id={`found-${i}`} role="option" aria-selected={i === at.value}
              class={i === at.value ? "on" : undefined} onMouseDown={(e) => { e.preventDefault(); pick(f.to); }}>
              <span class="found-title">{f.title}</span>
              <span class="found-detail">{f.detail}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function PersonMenu({ store, session }: { store: Store; session: Session }) {
  const open = useSignal(false);
  const confirming = useSignal(false);
  // Why Forget This Browser did not forget it, under the confirm, as the Remote's (#935).
  const forgetProblem = useSignal<string | null>(null);
  const box = useRef<HTMLDivElement>(null);
  const person = store.person.value;
  const admin = adminOf(store);
  useEffect(() => {
    if (!open.value) return;
    const away = (e: Event) => { if (!box.current?.contains(e.target as Node)) { open.value = false; confirming.value = false; } };
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") { open.value = false; confirming.value = false; } };
    addEventListener("mousedown", away);
    addEventListener("keydown", esc);
    return () => { removeEventListener("mousedown", away); removeEventListener("keydown", esc); };
  }, [open.value]);
  const role = person?.role === "admin" || admin === true ? "Admin" : person || admin === false ? "Member" : null;
  return (
    <div class="person-menu" ref={box}>
      <button type="button" class="person-button" aria-haspopup="menu" aria-expanded={open.value}
        aria-label={person ? `${person.name}: account` : "This browser: account"} onClick={() => { open.value = !open.value; }}>
        {initialOf(person?.name)}
      </button>
      {open.value && (
        <div class="person-list" role="menu" aria-label="Account">
          <div class="person-who">
            <span class="strong">{person?.name ?? "This browser"}</span>
            {role && <span class="quiet small">{role}</span>}
          </div>
          <button type="button" role="menuitem" onClick={() => { open.value = false; go({ nav: "settings" }); }}>Settings</button>
          {confirming.value ? (
            <div class="forget" role="group" aria-label="Forget This Browser">
              <p class="small">This browser is cut off at once, at home and away, until it is paired again.</p>
              <span class="confirm">
                <button type="button" class="danger" onClick={() => {
                  forgetProblem.value = null;
                  void session.forgetThisBrowser().then((problem) => (forgetProblem.value = problem));
                }}>Forget</button>
                <button type="button" onClick={() => { confirming.value = false; forgetProblem.value = null; }}>Cancel</button>
              </span>
            </div>
          ) : (
            <button type="button" role="menuitem" class="danger-text" onClick={() => (confirming.value = true)}>Forget This Browser…</button>
          )}
          {forgetProblem.value && <p class="failure small" role="alert">{forgetProblem.value}</p>}
        </div>
      )}
    </div>
  );
}

/** The trail over a page's title: each part but the last goes to its place. */
export function Crumbs({ parts }: { parts: readonly Crumb[] }) {
  return (
    <nav class="crumbs wide-only" aria-label="Breadcrumb">
      <ol>
        {parts.map((p, i) => (
          <li key={`${i}|${p.title}`}>
            {p.to && i < parts.length - 1
              ? <a href="#" onClick={(e) => { e.preventDefault(); go(p.to!); }}>{p.title}</a>
              : <span aria-current={i === parts.length - 1 ? "page" : undefined}>{p.title}</span>}
          </li>
        ))}
      </ol>
    </nav>
  );
}

/** A page's header: its breadcrumb, when it has more than one part, over its title. */
export function PageTitle({ parts, children }: { parts: readonly Crumb[]; children: ComponentChildren }) {
  return <div class="page-title">{parts.length > 1 && <Crumbs parts={parts} />}{children}</div>;
}

/** A chat's breadcrumb: Agents, its folder, its title. */
export function chatCrumbs(store: Store, host: string, title: string): Crumb[] {
  const r = route.value;
  const folder = r.folder ? (store.folders.value[host] ?? []).find((f) => folderKey(f.folder.folder) === folderKey(r.folder!)) : undefined;
  return [{ title: navTitle.agents, to: { nav: "agents" } }, ...(folder ? [{ title: folder.name }] : []), { title }];
}
