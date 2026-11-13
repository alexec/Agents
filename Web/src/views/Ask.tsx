// The one Ask card (#5031; specs/session-cards/spec.md, family 4): every question to the person has
// the same fixed head (glyph, title, asker), one body, and the same fixed foot (the ways to say no on
// the left, at most two buttons on the right, the primary one last). The yellow left edge is the one
// mark of "needs you" (#5016). The window and the Remote draw Shared/UI/Chat/AskCard.swift.
import type { ComponentChildren } from "preact";
import { useEffect, useRef } from "preact/hooks";
import { Icon, type IconName } from "./Icon";

export function Ask({ glyph, title, asker, label, alert = false, inert = false, extra, decline, buttons, children }: {
  glyph: IconName;
  /** What is asked, as a question or a name: the card's head. */
  title: ComponentChildren;
  /** Who asks, by title and runtime (#121), or a quiet fact such as +12 −3. */
  asker?: string | null | undefined;
  /** The card's name to a screen reader. */
  label: string;
  /** Said at once to a screen reader (an ask that arrived while the person reads). */
  alert?: boolean;
  /** Answered elsewhere or withdrawn: the whole card is greyed. */
  inert?: boolean;
  /** A class of its own, for what only this ask draws. */
  extra?: string;
  /** The ways to say no, as links on the foot's left: "No thanks · No, because…", Reject, Keep stopped. */
  decline?: ComponentChildren;
  /** The second button and the primary one, in that order. */
  buttons?: ComponentChildren;
  children?: ComponentChildren;
}) {
  const card = useRef<HTMLElement>(null);
  useAskKeys(card);
  return (
    <section ref={card} class={`card ask${inert ? " inert" : ""}${extra ? ` ${extra}` : ""}`} aria-label={label}
      {...(alert ? { role: "alert" } : {})}>
      <header class="ask-head">
        <Icon name={glyph} class="ask-glyph" />
        <span class="ask-title strong">{title}</span>
        {asker && <span class="ask-asker">{asker}</span>}
      </header>
      {children}
      {(decline || buttons) && (
        <footer class="ask-foot">
          <span class="ask-decline">{decline}</span>
          <span class="spacer" />
          {buttons}
        </footer>
      )}
    </section>
  );
}

/** The one label over every Ask, in the yellow of needs you (#5016). */
export const waitingForYou = "Waiting for you";

/** The actions past the foot's two buttons, in one ⋯ (spec rule 2). */
export function AskMore({ children }: { children: ComponentChildren }) {
  return (
    <details class="ask-more">
      <summary aria-label="More answers" title="More answers"><Icon name="ellipsis" /></summary>
      <div class="ask-more-menu" role="menu">{children}</div>
    </details>
  );
}

/**
 * The keys of the first Ask on the page (spec rule 4): ⌥1…9 press its `data-answer` buttons in
 * order, and Return its `data-default` one, unless a field, a menu or a link has the keys. The
 * window's are ⌘1…9; a browser keeps those for its tabs, so the page's are on Option.
 */
function useAskKeys(card: { current: HTMLElement | null }) {
  useEffect(() => {
    const press = (e: KeyboardEvent) => {
      const here = card.current;
      if (!here || e.defaultPrevented || e.isComposing) return;
      if (document.querySelector(".ask:not(.inert)") !== here) return;
      const digit = /^Digit([1-9])$/.exec(e.code);
      if (digit && e.altKey && !e.metaKey && !e.ctrlKey) {
        const answer = here.querySelectorAll<HTMLElement>("[data-answer]")[Number(digit[1]) - 1];
        if (answer) {
          e.preventDefault();
          answer.click();
        }
        return;
      }
      if (e.key !== "Enter" || e.altKey || e.metaKey || e.ctrlKey || e.shiftKey) return;
      const focused = document.activeElement;
      if (focused instanceof HTMLElement && focused.closest("input, textarea, select, button, a, summary, [contenteditable]")) return;
      const answer = here.querySelector<HTMLElement>("[data-default]");
      if (answer && !answer.hasAttribute("disabled") && answer.getAttribute("aria-disabled") !== "true") {
        e.preventDefault();
        answer.click();
      }
    };
    document.addEventListener("keydown", press);
    return () => document.removeEventListener("keydown", press);
  }, []);
}
