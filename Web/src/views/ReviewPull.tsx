// A pull request waiting for the person's approval in For Review (#3330), as the window's and the
// Remote's ReviewPullRowLabel (Shared/UI/ReviewPullRow.swift): the mark, the title with its folder,
// the time and one grey line, its number and repo. A press opens its page, with its screenshots, in a
// new tab; Dismiss, on hover and in its menu, takes it out for good.
import type { ReviewPull } from "../protocol/generated";
import type { Store } from "../model/store";
import { shortAgo } from "../model/activity";
import { fromWireDate } from "../protocol/dates";
import { holdForMenu, isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";

/** A pull request's mark: two branches joined, in the accent. */
export function PullMark() {
  return (
    <span class="sidebar-mark pull" aria-hidden="true">
      <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.4"
        stroke-linejoin="round" stroke-linecap="round">
        <circle cx="4" cy="3.5" r="1.6" /><circle cx="4" cy="12.5" r="1.6" /><circle cx="12" cy="12.5" r="1.6" />
        <path d="M4 5.1v5.8M12 10.9V6.5A2 2 0 0 0 10 4.5H7.5M9 3 7.5 4.5 9 6" />
      </svg>
    </span>
  );
}

/** "Pull request #3330 · alexec/agents". */
export function pullLine(pull: ReviewPull): string {
  return `Pull request #${pull.number} · ${pull.repo}`;
}

export function ReviewPullRow({ store, host, folder, pull, place, down }: {
  store: Store; host: string; folder: string; pull: ReviewPull; place: string; down: boolean;
}) {
  const at = fromWireDate(pull.updatedAt);
  const open = () => window.open(pull.url, "_blank", "noopener");
  const dismiss = () => void store.dismissReview(host, folder, pull.url);
  const menu = (): MenuItem[] => [
    { label: "Open Pull Request", run: open },
    { label: "Dismiss", disabled: down, help: "Out of For Review for good", run: dismiss },
  ];
  return (
    <div class="nav-item review-pull">
      <button class="row session pull" aria-description="pull request waiting for your approval"
        title={`${pull.title} · ${pullLine(pull)}`}
        onClick={open} onContextMenu={(e) => openContextMenu(e, menu())}
        onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu()); }} {...holdForMenu(menu)}>
        <PullMark />
        <span class="body">
          <span class="title placed">
            <span class="name">{pull.title}</span>
            <span class="place"> {place}</span>
          </span>
          <span class="subtitle">{pullLine(pull)}</span>
        </span>
        <time class="when" dateTime={at.toISOString()} title={at.toLocaleString()}>{shortAgo(at)}</time>
      </button>
      <button class="dismiss" disabled={down} onClick={dismiss} aria-label={`Dismiss ${pull.title}`}
        title="Take this pull request out of For Review">Dismiss</button>
    </div>
  );
}
