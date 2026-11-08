// One request to the person in Needs You (#3864): a question, a secret or a step an agent asked,
// as the window's and the Remote's RequestRowLabel (Shared/UI/ApprovalViews.swift). Its title is
// what is asked; its grey line, the kind, who asked it and how many sessions it blocks; its time,
// how long it has waited. A press opens the session that asked it, where its card takes the answer.
import type { Request as PersonRequest, RequestKind } from "../protocol/generated";
import type { Store } from "../model/store";
import { shortAgo } from "../model/activity";
import { fromWireDate } from "../protocol/dates";
import { go } from "../route";

const kindWords: Record<RequestKind, string> = {
  decide: "Question", approve: "Approval", account: "Account", step: "Step for you", secret: "Secret",
};

/** The grey line: the kind, the asker, and how many it blocks when more than one. */
export function requestLine(request: PersonRequest, asker: string | undefined): string {
  const blocks = Math.max(request.waiters.length, request.askedBy === undefined ? 0 : 1);
  return [kindWords[request.kind], asker, blocks > 1 ? `blocks ${blocks} sessions` : undefined]
    .filter(Boolean).join(" · ");
}

/** A request's mark: a speech bubble, in the attention tint. */
function RequestMark() {
  return (
    <span class="sidebar-mark approval" aria-hidden="true">
      <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.4"
        stroke-linejoin="round" stroke-linecap="round">
        <path d="M2.25 3.25h11.5v7.5H7l-3 2.5v-2.5H2.25z" />
      </svg>
    </span>
  );
}

export function RequestRow({ store, host, folder, request, place, chosen }: {
  store: Store; host: string; folder: string; request: PersonRequest; place: string; chosen: boolean;
}) {
  const asker = request.askedBy as string;
  const since = fromWireDate(request.askedAt);
  const line = requestLine(request, store.agent(host, asker)?.title);
  return (
    <div class="nav-item">
      <button class={`row session approval${chosen ? " chosen" : ""}`} aria-current={chosen}
        aria-description="waiting for your answer" title={line} onClick={() => go({ host, folder, session: asker })}>
        <RequestMark />
        <span class="body">
          <span class="title placed">
            <span class="name">{request.title}</span>
            <span class="place"> {place}</span>
          </span>
          <span class="subtitle">{line}</span>
        </span>
        <time class="when" dateTime={since.toISOString()} title={since.toLocaleString()}>{shortAgo(since)}</time>
      </button>
    </div>
  );
}
