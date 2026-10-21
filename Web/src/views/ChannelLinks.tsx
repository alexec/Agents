// A channel identity's ask to be linked (#1762, spec 736 US7), as the window's and the Remote's link
// card (Shared/UI/People/ChannelLinkCard.swift): "Link Slack user @sam to you?" with Approve or Deny,
// or for an admin, a request that names nobody with a person to send it on to. At the top of the
// sidebar beside the join cards, and in Settings ▸ Channels with the links themselves.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { ChannelLink, ChannelLinkRequest } from "../protocol/generated";
import { describe } from "../model/errors";
import { ask, detail, explanation, foot, linkDetail, linkTitle, liveRequests, none, removeMessage, removeTitle, title } from "../model/channelLinks";
import { ApprovalMark } from "./Approval";

function LinkCard({ store, request, down }: { store: Store; request: ChannelLinkRequest; down: boolean }) {
  const sendTo = useSignal("");
  const question = ask(request);
  const more = detail(request);
  return (
    <li class="join-request" aria-label={question}>
      <ApprovalMark />
      <div class="body">
        <span class="title"><strong>{question}</strong></span>
        {more && <span class="subtitle">{more}</span>}
        {!request.for && (
          <select aria-label="Person" value={sendTo.value} disabled={down}
            onChange={(e) => (sendTo.value = (e.currentTarget as HTMLSelectElement).value)}>
            <option value="">Choose…</option>
            {store.linkPeople.value.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
        )}
        <div class="join-actions">
          <button type="button" disabled={down} onClick={() => void store.decideLink(request.request, false)}>Deny</button>
          {request.for
            ? <button type="button" class="prominent" disabled={down} onClick={() => void store.decideLink(request.request, true)}>Approve</button>
            : <button type="button" class="prominent" disabled={down || !sendTo.value}
                onClick={() => void store.decideLink(request.request, true, sendTo.value)}>Send</button>}
        </div>
        <span class="subtitle">{explanation(request)}</span>
      </div>
    </li>
  );
}

/** Every channel identity waiting to be linked, or nothing. */
export function LinkRequests({ store, down }: { store: Store; down: boolean }) {
  const waiting = liveRequests(store.linkRequests.value);
  if (waiting.length === 0) return null;
  return (
    <section class="join-requests" aria-label="Channel identities waiting to be linked">
      <ul>{waiting.map((request) => <LinkCard key={request.request} store={store} request={request} down={down} />)}</ul>
    </section>
  );
}

/** Settings ▸ Channels (#1762): the requests waiting, and the links, each with Remove. */
export function ChannelsSection({ store, down }: { store: Store; down: boolean }) {
  const links = useSignal<ChannelLink[] | null>(null);
  const problem = useSignal<string | null>(null);
  const load = async () => {
    try {
      links.value = await store.link.call("links/list", {});
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    }
  };
  // Again on each control/linksChanged, and on each connection.
  const changes = store.linksChanges.value;
  useEffect(() => { if (!down) void load(); }, [changes, down]);
  const remove = async (link: ChannelLink) => {
    if (!window.confirm(`${removeTitle(link)} ${removeMessage}`)) return;
    try {
      await store.link.call("links/remove", { channel: link.channel, identity: link.identity });
    } catch (error) {
      store.say(describe(error));
    }
    await load();
  };
  const shown = links.value;
  const you = store.person.value?.id;
  return (
    <section aria-labelledby="settings-channels">
      <h3 class="section-head" id="settings-channels">{title}</h3>
      <LinkRequests store={store} down={down} />
      {problem.value && <p class="hint">{problem.value}</p>}
      {!shown && !problem.value && <p class="hint">Loading…</p>}
      {shown && (
        <>
          {shown.length === 0 && <p class="hint">{none}</p>}
          <ul class="people-list">
            {shown.map((link) => (
              <li key={`${link.channel}\n${link.identity}`} class="person">
                <div class="setting"><span class="person-name">{linkTitle(link)}</span></div>
                <div class="person-things">
                  <span class="small">{linkDetail(link, you)}</span>
                  <span>
                    <button type="button" class="link destructive" disabled={down} onClick={() => void remove(link)}>Remove…</button>
                  </span>
                </div>
              </li>
            ))}
          </ul>
          <p class="hint">{foot}</p>
        </>
      )}
    </section>
  );
}
