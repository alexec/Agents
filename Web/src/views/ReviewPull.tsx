// A pull request waiting for the person's approval in For Review (#3330), as the window's and the
// Remote's ReviewPullRowLabel (Shared/UI/ReviewPullRow.swift): the mark, the title with its folder,
// the time and one grey line, its number and repo. It is a link, with the title drawn as one: a press
// opens its Work page, with its screenshots in its body, or its forge page in a new tab when the host
// said no ref, and from then on its title is not bold (#3464); Dismiss, on hover and in its menu,
// takes it out for good.
import type { ReviewPull } from "../protocol/generated";
import type { Store } from "../model/store";
import { shortAgo } from "../model/activity";
import { fromWireDate } from "../protocol/dates";
import { go, routeHash } from "../route";
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
  const opened = () => void store.openReview(host, folder, pull.url);
  // Its Work page in the app; a host with no ref leaves only its forge page.
  const page = pull.ref ? { nav: "work", section: "pr", item: pull.ref } as const : null;
  const open = () => {
    if (page) go(page); else window.open(pull.url, "_blank", "noopener");
    opened();
  };
  const dismiss = () => void store.dismissReview(host, folder, pull.url);
  const menu = (): MenuItem[] => [
    { label: "Open Pull Request", run: open },
    { label: "Dismiss", disabled: down, help: "Out of For Review for good", run: dismiss },
  ];
  return (
    <div class={`nav-item review-pull${pull.opened ? "" : " unread"}`}>
      <a class="row session pull" href={page ? routeHash(page) : pull.url}
        {...(page ? {} : { target: "_blank", rel: "noopener" })}
        aria-description={`${pull.opened ? "" : "unread "}pull request waiting for your approval${page ? "" : ", opens in a new tab"}`}
        onClick={opened} onAuxClick={(e) => { if (e.button === 1) opened(); }}
        title={`${pull.title} · ${pullLine(pull)}`}
        onContextMenu={(e) => openContextMenu(e, menu())}
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
      </a>
      <button class="dismiss" disabled={down} onClick={dismiss} aria-label={`Dismiss ${pull.title}`}
        title="Take this pull request out of For Review">Dismiss</button>
    </div>
  );
}
