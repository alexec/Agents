// The Strip family of session cards (#5034, specs/session-cards/spec.md, family 1): what is wrong with the
// session's place, at the top of its chat: the host, the folder, the account, the allowance or the limit. One
// shows at a time, in that order; "+N more" opens the others under it. The window and the Remote draw the same
// in Shared/UI/Chat/SessionStrip.swift, with the same words.
//
// A strip is on the well, as the Now card is: a glyph, one line and a quiet detail, at most two buttons (the
// primary on the right) and ⋯ for the rest. The glyph is the warning's orange when something is wrong, never
// yellow, which is for an Ask (#5016); a state the app works through by itself has a grey glyph.
import type { ComponentChildren, JSX } from "preact";
import { createContext } from "preact";
import { useContext, useState } from "preact/hooks";
import { Icon, type IconName } from "./Icon";

export type StripTone = "neutral" | "warning";

/** The order of a session's strips (SessionStripKind). */
export const stripOrder = ["host", "folder", "account", "allowance", "limit"] as const;
export type StripKind = (typeof stripOrder)[number];

export const showLess = "Show less";
/** "+2 more", the link to the strips under the first. */
export const moreStrips = (count: number) => `+${count} more`;

/** One of a strip's buttons, or a line of its ⋯ menu. */
export type StripButton = { label: string; run: () => void; title?: string; disabled?: boolean };

const MoreContext = createContext<{ count: number; open: boolean; toggle: () => void } | null>(null);

export function Strip({ tone, name, icon, busy, line, detail, title, primary, second, more = [], accessory }: {
  tone: StripTone; name?: string; icon?: IconName; busy?: boolean; line: ComponentChildren; detail?: string | null;
  title?: string; primary?: StripButton | null; second?: StripButton | null; more?: StripButton[]; accessory?: ComponentChildren;
}): JSX.Element {
  const stack = useContext(MoreContext);
  const button = (b: StripButton, cls?: string) => (
    <button type="button" class={cls} disabled={b.disabled} title={b.title} onClick={b.run}>{b.label}</button>
  );
  return (
    <div class={`strip tone-${tone}${name ? ` ${name}` : ""}`} role="status">
      {busy ? <span class="strip-glyph spinner" aria-hidden="true" />
        : <span class="strip-glyph" aria-hidden="true"><Icon name={icon ?? (tone === "warning" ? "triangle-alert" : "info")} /></span>}
      <span class="strip-words" title={title ?? (typeof line === "string" ? [line, detail].filter(Boolean).join(" · ") : undefined)}>
        {line}{detail && <span class="quiet"> · {detail}</span>}
      </span>
      <span class="strip-actions">
        {accessory}
        {second && button(second)}
        {primary && button(primary, "prominent")}
        {more.length > 0 && (
          <details class="ask-more strip-more-menu">
            <summary aria-label="More" title="More"><Icon name="ellipsis" /></summary>
            <div class="ask-more-menu" role="menu">{more.map((b) => button(b))}</div>
          </details>
        )}
        {stack && <button type="button" class="link strip-more" aria-expanded={stack.open} onClick={stack.toggle}>
          {stack.open ? showLess : moreStrips(stack.count)}</button>}
      </span>
    </div>
  );
}

/** A session's strips, one at a time: the first, with "+N more" on it, and the others under it once that is
 *  pressed. `strips` are in `stripOrder`, each only when it applies. */
export function Strips({ strips }: { strips: { kind: StripKind; node: JSX.Element }[] }): JSX.Element | null {
  const [open, setOpen] = useState(false);
  const [first, ...rest] = strips;
  if (!first) return null;
  const isOpen = open && rest.length > 0;
  return (
    <div class="strips">
      <MoreContext.Provider value={rest.length ? { count: rest.length, open: isOpen, toggle: () => setOpen(!isOpen) } : null}>
        {first.node}
      </MoreContext.Provider>
      {isOpen && rest.map((s) => <div key={s.kind}>{s.node}</div>)}
    </div>
  );
}
