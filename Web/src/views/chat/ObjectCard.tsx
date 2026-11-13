// The one Object card (#5035; specs/session-cards/spec.md, family 3): a thing the agent made, to open. A raised
// box: the preview when there is one, then one row of the kind's icon, the name, a quiet line (kind · place), ⋯
// for the rest and › when a click opens it. A file shown with show_file, what a turn changed and an app view's
// frame are all drawn with it. The window and the Remote draw the same in Shared/UI/Chat/ObjectCard.swift.
import type { ComponentChildren, JSX } from "preact";
import { Icon, type IconName } from "../Icon";
import type { StripButton } from "../Strip";

export function ObjectCard({ icon, title, detail, open, openTitle, more = [], tapAnywhere = true, preview, notes, wide }: {
  icon: IconName; title: string; detail: string;
  /** What a click does; none draws the card with no ›. */
  open?: (() => void) | undefined; openTitle?: string;
  /** The actions that are not the click: Undo These Changes, Pin to Folder, Full Screen. */
  more?: StripButton[];
  /** False when the preview is live (an app view): only the name and › open, as the view takes its own clicks. */
  tapAnywhere?: boolean;
  preview?: ComponentChildren; notes?: ComponentChildren;
  /** An app view is as wide as the chat; a file or a change is at most 360. */
  wide?: boolean;
}): JSX.Element {
  const words = (
    <>
      <Icon name={icon} class="object-card-icon" />
      <span class="object-card-words">
        <span class="object-card-name">{title}</span>
        <span class="object-card-detail">{detail}</span>
      </span>
    </>
  );
  return (
    <div class={`object-card${wide ? " wide" : ""}${open ? " opens" : ""}`}>
      {preview !== undefined && (open && tapAnywhere
        // A click on the preview opens too; the row's button is the one a keyboard reaches.
        ? <div class="object-card-preview" aria-hidden="true" onClick={open}>{preview}</div>
        : <div class="object-card-preview">{preview}</div>)}
      <div class="object-card-row">
        {open
          ? <button type="button" class="object-card-open" title={openTitle} aria-label={`${title}, ${detail}`} onClick={open}>{words}</button>
          : <span class="object-card-open" aria-label={`${title}, ${detail}`}>{words}</span>}
        {more.length > 0 && (
          <details class="ask-more object-card-more">
            <summary aria-label="More" title="More"><Icon name="ellipsis" /></summary>
            <div class="ask-more-menu" role="menu">
              {more.map((b) => <button key={b.label} type="button" disabled={b.disabled} title={b.title}
                onClick={(e) => { (e.currentTarget.closest("details") as HTMLDetailsElement | null)?.removeAttribute("open"); b.run(); }}>{b.label}</button>)}
            </div>
          </details>
        )}
        {open && <button type="button" class="object-card-chevron" title={openTitle} aria-label={openTitle ?? title} tabIndex={-1} onClick={open}>
          <Icon name="chevron-right" /></button>}
      </div>
      {notes}
    </div>
  );
}
