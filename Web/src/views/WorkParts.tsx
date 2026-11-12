// The shared parts of Work's look (#4392, specs/4328-work-look/parts.md, sections 1 to 7), as Shared/UI's on the
// window and the Remote (#4391): the state icon, the label chip in its colour, a filter's menu button, an avatar,
// the placeholder rows of a first read and an empty list's middle.
import type { ComponentChildren } from "preact";
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { ForgeLabel } from "../protocol/generated";
import { MessageBanner } from "./MessageKinds";
import { avatarHue, chipColours, labelScope, stateGlyph, stateGlyphWords, type StateGlyph } from "../model/work";

const glyphPaths: Record<StateGlyph, ComponentChildren> = {
  "issue-open": <><circle cx="8" cy="8" r="6.25" /><circle cx="8" cy="8" r="1.5" class="fill" /></>,
  "issue-done": <><circle cx="8" cy="8" r="6.25" /><path d="M5.2 8.3 7.2 10.3 10.9 6.1" /></>,
  "issue-dropped": <><circle cx="8" cy="8" r="6.25" /><path d="M4.1 11.9 11.9 4.1" /></>,
  "pr-open": <><circle cx="4" cy="3.5" r="1.75" /><circle cx="4" cy="12.5" r="1.75" /><circle cx="12" cy="12.5" r="1.75" />
    <path d="M4 5.25v5.5M12 10.75V6.5A2.5 2.5 0 0 0 9.5 4H7M8.6 2.4 7 4l1.6 1.6" /></>,
  "pr-draft": <><circle cx="4" cy="3.5" r="1.75" /><circle cx="4" cy="12.5" r="1.75" /><circle cx="12" cy="12.5" r="1.75" />
    <path d="M4 5.25v5.5M12 8.5v.01M12 5.5v.01" /></>,
  "pr-merged": <><circle cx="4" cy="3.5" r="1.75" /><circle cx="4" cy="12.5" r="1.75" /><circle cx="12" cy="8" r="1.75" />
    <path d="M4 5.25v5.5M4 5.25C4 8 6.5 8 10.25 8" /></>,
  "pr-closed": <><circle cx="4" cy="3.5" r="1.75" /><circle cx="4" cy="12.5" r="1.75" /><circle cx="12" cy="12.5" r="1.75" />
    <path d="M4 5.25v5.5M12 10.75V8.5M10.4 3.4l3.2 3.2M13.6 3.4l-3.2 3.2" /></>,
};

/** One glyph in the state's colour (section 1), with its words for a screen reader; nothing for a release. */
export function StateIcon({ kind, state, draft, stateReason, size = 16 }: {
  kind: string; state: string; draft?: boolean | undefined; stateReason?: string | undefined; size?: number;
}) {
  const glyph = stateGlyph(kind, state, draft, stateReason === "not_planned");
  if (!glyph) return null;
  return (
    <svg class={`work-state-icon ${glyph}`} width={size} height={size} viewBox="0 0 16 16" role="img" aria-label={stateGlyphWords[glyph]}>
      <title>{stateGlyphWords[glyph]}</title>
      {glyphPaths[glyph]}
    </svg>
  );
}

/** A label in its forge's colour (section 3, #2956): the colour at 18 % for the fill, 60 % for the border, the text
 * at 4.5:1 to the fill, in light and dark; a scoped label's scope in the regular weight. A click picks it as the
 * Label filter, where the list gives `pick`. */
export function LabelChip({ label, pick }: { label: ForgeLabel; pick?: ((name: string) => void) | undefined }) {
  const light = chipColours(label.color, "light");
  const dark = chipColours(label.color, "dark");
  const style = light && dark ? {
    "--chip-fill": light.fill, "--chip-border": light.border, "--chip-ink": light.ink,
    "--chip-fill-dark": dark.fill, "--chip-border-dark": dark.border, "--chip-ink-dark": dark.ink,
  } : undefined;
  const scope = labelScope(label.name);
  const words = scope ? <><span class="scope">{scope[0]}</span>{scope[1]}</> : label.name;
  // In a row, which is one button, the chip takes the click itself; a keyboard picks the label from the Label menu.
  return (
    <span class={`work-label${style ? " coloured" : ""}${pick ? " picks" : ""}`} style={style}
      title={pick ? `Show only ${label.name}` : undefined}
      onClick={pick ? (e) => { e.stopPropagation(); e.preventDefault(); pick(label.name); } : undefined}>{words}</span>
  );
}

/** Reads a forge's picture by its URL (forge/image on the machine that read the item, #4363), as a URL the page can draw. */
export type ReadPicture = (url: string) => Promise<string | null>;

/** The pictures read so far, by URL, so a person's avatar is read once for every row and page, and a picture that did
 * not load is not asked for again. At most `mostPictures` are kept. */
const pictures = new Map<string, Promise<string | null>>();
const mostPictures = 500;

/** `url`'s picture as an object URL, read with `read` the first time; null when it did not load. */
export function picture(url: string, read: (url: string) => Promise<{ bytes: Uint8Array; type: string }>): Promise<string | null> {
  const had = pictures.get(url);
  if (had) return had;
  if (pictures.size >= mostPictures) {
    for (const p of pictures.values()) void p.then((u) => { if (u) URL.revokeObjectURL(u); });
    pictures.clear();
  }
  const got = read(url).then((p) => URL.createObjectURL(new Blob([p.bytes as BlobPart], { type: p.type })), () => null);
  pictures.set(url, got);
  return got;
}

/** A person (section 6): the forge's picture where it gives one and `read` can read it (#4363); else, or until it loads,
 * the login's first letter on a colour picked from the login. */
export function Avatar({ login, size = 20, url, read }: { login: string; size?: number; url?: string | undefined; read?: ReadPicture | undefined }) {
  const src = useSignal<string | null>(null);
  useEffect(() => {
    src.value = null;
    if (!url || !read) return;
    let live = true;
    void read(url).then((u) => { if (live) src.value = u; });
    return () => { live = false; };
  }, [url, read]);
  const box = { width: `${size}px`, height: `${size}px` };
  if (src.value) return <img class="work-avatar" src={src.value} alt="" title={login} aria-hidden="true" style={box} />;
  return (
    <span class="work-avatar" title={login} aria-hidden="true"
      style={{ "--hue": avatarHue(login), ...box, fontSize: `${Math.round(size * 0.5)}px` }}>
      {login.replace(/^@/, "").charAt(0).toUpperCase()}
    </span>
  );
}

/** Up to three assignees, overlapped, then "+2" (section 2). `avatars` are the pictures the forge gives, by login (the
 * author's, #4363): the rest are initials. */
export function Avatars({ logins, avatars = {}, read }: { logins: readonly string[]; avatars?: Record<string, string>; read?: ReadPicture | undefined }) {
  if (logins.length === 0) return null;
  return (
    <span class="work-avatars" aria-label={`Assigned to ${logins.join(", ")}`}>
      {logins.slice(0, 3).map((l) => <Avatar key={l} login={l} url={avatars[l]} read={read} />)}
      {logins.length > 3 && <span class="more">+{logins.length - 3}</span>}
    </span>
  );
}

export interface MenuChoice { value: string; words: string }

/** A filter's menu (section 4): a borderless button with the filter's name and a chevron that opens a list, in place of
 * a `<select>`. Set, it shows its value in the accent colour ("Label: bug ▾"); `always` shows the value with no name
 * ("Open ▾"), for a filter that always has one; `standard` shows the name alone at that value ("Sort ▾"), for an order,
 * which filters nothing, and "Sort: Cost ▾" in the accent at any other (lists.md section 1). `any`, when given, is the
 * item at the top that clears it. */
export function FilterMenu({ label, value, choices, any, always, standard, onPick }: {
  label: string; value: string; choices: readonly MenuChoice[]; any?: string | undefined; always?: boolean; standard?: string;
  onPick: (value: string) => void;
}) {
  const open = useSignal<{ left: number; top: number } | null>(null);
  const anchor = useRef<HTMLSpanElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const chosen = choices.find((c) => c.value === value);
  const set = !!value && !always && value !== standard;
  const words = always ? chosen?.words ?? label : set ? `${label}: ${chosen?.words ?? value}` : label;
  useEffect(() => {
    if (!open.value) return;
    const close = (e: Event) => { if (!anchor.current?.contains(e.target as Node)) open.value = null; };
    const escape = (e: KeyboardEvent) => { if (e.key === "Escape") { open.value = null; anchor.current?.querySelector("button")?.focus(); } };
    const away = () => { open.value = null; };
    addEventListener("pointerdown", close);
    addEventListener("keydown", escape);
    addEventListener("resize", away);
    // A scroll of the page moves the button from under the list; the list's own scroll does not.
    const scrolled = (e: Event) => { if (!menu.current?.contains(e.target as Node)) away(); };
    addEventListener("scroll", scrolled, true);
    menu.current?.querySelector<HTMLElement>("[aria-checked=true], [role=menuitemradio]")?.focus();
    return () => {
      removeEventListener("pointerdown", close); removeEventListener("keydown", escape);
      removeEventListener("resize", away); removeEventListener("scroll", scrolled, true);
    };
  }, [open.value !== null]);
  const toggle = (e: MouseEvent) => {
    if (open.value) { open.value = null; return; }
    // Fixed to the button, so a row of menus that scrolls (390 px) does not clip the list.
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    open.value = { left: Math.max(8, Math.min(r.left, innerWidth - 248)), top: r.bottom + 4 };
  };
  const pick = (v: string) => { open.value = null; onPick(v); anchor.current?.querySelector("button")?.focus(); };
  const keys = (e: KeyboardEvent) => {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    e.preventDefault();
    const items = [...menu.current?.querySelectorAll<HTMLElement>("[role=menuitemradio]") ?? []];
    const at = items.indexOf(document.activeElement as HTMLElement);
    items[(at + (e.key === "ArrowDown" ? 1 : items.length - 1)) % items.length]?.focus();
  };
  const all: MenuChoice[] = [...any !== undefined ? [{ value: "", words: any }] : [], ...choices];
  return (
    <span class="work-menu" ref={anchor}>
      <button type="button" class={`work-menu-button${set ? " set" : ""}`} aria-haspopup="menu" aria-expanded={open.value !== null}
        aria-label={`${label}: ${chosen?.words ?? any ?? label}`} onClick={toggle}>
        {words}<span class="chevron" aria-hidden="true">▾</span>
      </button>
      {open.value && (
        <div class="popover work-menu-list" role="menu" aria-label={label} ref={menu} onKeyDown={keys}
          style={{ left: `${open.value.left}px`, top: `${open.value.top}px` }}>
          {all.map((c) => (
            <button key={c.value} type="button" role="menuitemradio" aria-checked={c.value === value} onClick={() => pick(c.value)}>{c.words}</button>
          ))}
        </div>
      )}
    </span>
  );
}

/** Refresh (section 4): the standard two-arrow circle (as the Mac's and the Remote's
 * `arrow.triangle.2.circlepath`), which turns about its centre while a read runs. */
export function RefreshButton({ busy, onClick }: { busy: boolean; onClick: () => void }) {
  return (
    <button type="button" class={`work-refresh${busy ? " busy" : ""}`} title="Refresh" aria-label={busy ? "Refreshing" : "Refresh"} onClick={onClick}>
      <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><path d="M2.75 8a5.25 5.25 0 0 1 9.1-3.57M13.25 8a5.25 5.25 0 0 1-9.1 3.57M12.25 1.75v3h-3M3.75 14.25v-3h3" /></svg>
    </button>
  );
}

/** A first read (section 7): six placeholder rows (or `count`), a circle and two bars each, with a slow shimmer. */
export function PlaceholderRows({ count = 6 }: { count?: number }) {
  return (
    <ul class="work-rows work-item-rows work-placeholder" aria-busy="true" aria-label="Loading">
      {[62, 48, 70, 40, 56, 66].slice(0, count).map((w, i) => (
        <li key={i} aria-hidden="true"><span class="work-row work-item-row">
          <span class="dot" /><span class="work-row-main"><span class="bar" style={{ width: `${w}%` }} /><span class="bar short" style={{ width: `${w / 2}%` }} /></span>
        </span></li>
      ))}
    </ul>
  );
}

/** An empty list's middle (section 7): the page's glyph, a heading, one line and a button. */
export function EmptyState({ kind, title, line, action }: {
  kind: string; title: string; line?: string | undefined; action?: { words: string; run: () => void } | undefined;
}) {
  return (
    <div class="work-empty">
      {(kind === "issue" || kind === "pr") && <StateIcon kind={kind} state="open" size={32} />}
      <p class="strong">{title}</p>
      {line && <p class="quiet">{line}</p>}
      {action && <button type="button" onClick={action.run}>{action.words}</button>}
    </div>
  );
}

/** A forge that could not be read (section 7): a strip with what it said and Try again. In the middle of a list that read
 * nothing, a heading first ("Could not read issues", lists.md section 5), and `also` beside Try again (Settings ▸
 * Connectors, for a credential the forge refused). */
export function ErrorStrip({ lines, retry, middle, title, also }: {
  lines: readonly string[]; retry: () => void; middle?: boolean; title?: string | undefined;
  also?: { words: string; run: () => void } | undefined;
}) {
  if (lines.length === 0) return null;
  return (
    // A banner of the list (docs/reference/design-system.md, "Messages"): a failure, with a red ✕, not the amber wash.
    <MessageBanner tone="failure" name={`work-error${middle ? " middle" : ""}`} actions={<>
      <button type="button" onClick={retry}>Try again</button>
      {also && <button type="button" onClick={also.run}>{also.words}</button>}
    </>}>
      {title && <span class="strong">{title}</span>}{lines.map((l) => <span key={l}>{l}</span>)}
    </MessageBanner>
  );
}
