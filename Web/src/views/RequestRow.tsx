// One request to the person in Needs You (#3864): a question, a secret or a step an agent asked,
// as the window's and the Remote's RequestRowLabel (Shared/UI/ApprovalViews.swift). Its title is
// what is asked; its grey line, the kind, who asked it and how many sessions it blocks; its time,
// how long it has waited. A press opens the session that asked it, where its card takes the answer.
// A secret's use (#4017) has no card: its title says which secret, its grey line the asker and
// where the value goes, and its menu (a right click, a long press or the menu key) has Allow Once, Allow
// for This Session, Allow Always and Deny, as the window's and the Remote's menus have.
// Its mark is one for each kind (#4026), as NeedRequest.symbol is: unlike an approval's one shield,
// it says what is asked. The step's hand taps: the raised hand is a session that needs the person.
import type { Request as PersonRequest, RequestKind } from "../protocol/generated";
import type { Store } from "../model/store";
import { shortAgo } from "../model/activity";
import { fromWireDate } from "../protocol/dates";
import { go } from "../route";
import { holdForMenu, isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";
import { secretUseActions, secretUseOf, secretUseTitle, secretUseWhere, secretUseWords } from "../model/secretUse";

const kindWords: Record<RequestKind, string> = {
  decide: "Question", approve: "Approval", account: "Account", step: "Step for you", secret: "Secret",
};

/** The grey line: the kind, the asker, and how many it blocks when more than one. */
export function requestLine(request: PersonRequest, asker: string | undefined): string {
  const blocks = Math.max(request.waiters.length, request.askedBy === undefined ? 0 : 1);
  const use = secretUseOf(request);
  return [...(use ? [asker, secretUseWhere(use)] : [kindWords[request.kind], asker]), blocks > 1 ? `blocks ${blocks} sessions` : undefined]
    .filter(Boolean).join(" · ");
}

/** Each kind's mark, drawn as its SF Symbol in NeedRequest.symbol: questionmark.bubble,
 * checkmark.shield, person.badge.plus, hand.tap and key. */
const kindMarks: Record<RequestKind, string[]> = {
  decide: ["M2.25 2.75h11.5v8H7l-3 2.5v-2.5H2.25z", "M6.4 5.4a1.6 1.6 0 1 1 2.3 1.45c-.45.2-.7.55-.7 1v.3", "M8 9.6v.01"],
  approve: ["M8 1.75 2.75 3.75v4c0 3.1 2.2 5.3 5.25 6.5 3.05-1.2 5.25-3.4 5.25-6.5v-4z", "m5.6 8.1 1.7 1.7 3.2-3.4"],
  account: ["M6.5 7.25a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5z", "M1.75 14c0-2.75 2.1-4.5 4.75-4.5 1.1 0 2.1.3 2.9.85",
    "M12.5 9.25v4.5M10.25 11.5h4.5"],
  step: ["M6.25 8.5V3a1.25 1.25 0 0 1 2.5 0v4.25", "M8.75 6.75a1.25 1.25 0 0 1 2.5 0v.75",
    "M11.25 7.25a1.25 1.25 0 0 1 2.5 0v2.5c0 2.6-1.9 4.5-4.5 4.5H8.5c-1.3 0-2.3-.6-3-1.6L3.2 9.9a1.2 1.2 0 0 1 1.9-1.4l1.15 1.25",
    "M4 3.75a3.25 3.25 0 0 1 .9-2.2M11 3.75a3.25 3.25 0 0 0-.9-2.2"],
  secret: ["M5.25 13.25a3 3 0 1 0 0-6 3 3 0 0 0 0 6z", "m7.4 8.1 5.6-5.6M11 4.5l1.75 1.75M9.5 6l1.25 1.25"],
};

/** A request's mark, its kind's, in the attention tint. */
function RequestMark({ kind }: { kind: RequestKind }) {
  return (
    <span class="sidebar-mark approval" aria-hidden="true">
      <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.4"
        stroke-linejoin="round" stroke-linecap="round">
        {(kindMarks[kind] ?? kindMarks.decide).map((d) => <path key={d} d={d} />)}
      </svg>
    </span>
  );
}

export function RequestRow({ store, host, folder, request, place, chosen }: {
  store: Store; host: string; folder: string; request: PersonRequest; place: string; chosen: boolean;
}) {
  const asker = request.askedBy as string;
  const since = fromWireDate(request.askedAt);
  const askerTitle = store.agent(host, asker)?.title;
  const line = requestLine(request, askerTitle);
  const use = secretUseOf(request);
  const open = () => go({ host, folder, session: asker });
  const menu = (): MenuItem[] => [
    ...(use ? secretUseActions(use).map((action) => ({
      label: secretUseWords[action], run: () => void store.answerSecretUse(host, request.id, action),
    })) : []),
    { label: "Open Session", run: open },
  ];
  return (
    <div class="nav-item">
      <button class={`row session approval${chosen ? " chosen" : ""}`} aria-current={chosen}
        aria-description="waiting for your answer" title={line} onClick={open}
        onContextMenu={(e) => openContextMenu(e, menu())}
        onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu()); }} {...holdForMenu(menu)}>
        <RequestMark kind={request.kind} />
        <span class="body">
          <span class="title placed">
            <span class="name">{use ? secretUseTitle(use) : request.title}</span>
            <span class="place"> {place}</span>
          </span>
          <span class="subtitle">{line}</span>
        </span>
        <time class="when" dateTime={since.toISOString()} title={since.toLocaleString()}>{shortAgo(since)}</time>
      </button>
    </div>
  );
}
