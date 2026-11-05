// The machine lock's cards (#3490, specs/3399-machine-lock D2), beside the sign-in cards and in
// their look: this browser's own card while it is not in its person's lock, and a card for each
// other device that asks to join. The words are the window's and the Remote's, so the three
// clients match. A control plane without lock-join/1 shows nothing.
import type { Store } from "../model/store";
import { brokenWords, type SignerCard, type ThisDevice } from "../model/machineLock";
import { spaced } from "../wire/machineLock";
import { ApprovalMark } from "./Approval";

function OwnCard({ store, device, down }: { store: Store; device: ThisDevice; down: boolean }) {
  let title;
  let subtitle = null;
  let action = null;
  switch (device.kind) {
    case "asking":
      title = <>Approve this device on another of your devices.</>;
      subtitle = device.digits
        ? <>Check that the other device shows <code>{spaced(device.digits)}</code>, then approve it there.</>
        : <>Open Agents on a device you use already and choose Compare Digits.</>;
      break;
    case "ended":
      title = device.result === "denied" ? <>This device was not approved.</> : <>Nobody approved this device in time.</>;
      action = <button type="button" class="prominent" disabled={down} onClick={() => void store.machineLock.askAgain()}>Ask Again</button>;
      break;
    case "broken":
      title = <>{brokenWords(device)}</>;
      break;
    default:
      return null;
  }
  return (
    <li class="join-request lock-join-own">
      <ApprovalMark />
      <div class="body">
        <span class="title">{title}</span>
        {subtitle && <span class="subtitle">{subtitle}</span>}
        {action && <div class="join-actions">{action}</div>}
      </div>
    </li>
  );
}

function RequestCard({ store, card, down }: { store: Store; card: SignerCard; down: boolean }) {
  const { request, view } = card;
  const lock = store.machineLock;
  const deny = <button type="button" disabled={down} onClick={() => void lock.deny(request.request)}>Deny</button>;
  let title;
  let subtitle = null;
  let prominent = null;
  switch (view.kind) {
    case "compare":
      title = <><strong>{request.name}</strong> asks to join your devices.</>;
      subtitle = <>Compare the digits on both screens before you approve it.</>;
      prominent = <button type="button" class="prominent" disabled={down} onClick={() => void lock.compare(request.request)}>Compare Digits</button>;
      break;
    case "another":
      title = <>Another of your devices is comparing the digits.</>;
      break;
    case "waiting":
      title = <>Waiting for {request.name} to show its digits…</>;
      break;
    case "digits":
      title = <>Approve only if {request.name} shows <code>{spaced(view.digits)}</code>.</>;
      prominent = <button type="button" class="prominent" disabled={down} onClick={() => void lock.approve(request.request)}>Approve</button>;
      break;
    case "notPromised":
      title = <>{request.name} did not show the digits it promised. Deny it.</>;
      break;
  }
  return (
    <li class="join-request" aria-label={`${request.name} asks to join your devices`}>
      <ApprovalMark />
      <div class="body">
        <span class="title">{title}</span>
        {subtitle && <span class="subtitle">{subtitle}</span>}
        <div class="join-actions">{deny}{prominent}</div>
      </div>
    </li>
  );
}

/** This browser's lock card and every device that asks to join, or nothing. */
export function LockJoins({ store, down }: { store: Store; down: boolean }) {
  const device = store.machineLock.device.value;
  const cards = store.machineLock.cards.value;
  const own = device.kind === "asking" || device.kind === "ended" || device.kind === "broken";
  if (!own && cards.length === 0) return null;
  return (
    <section class="join-requests" aria-label="Devices waiting to join your lock">
      <ul>
        {own && <OwnCard store={store} device={device} down={down} />}
        {cards.map((card) => <RequestCard key={card.request.request} store={store} card={card} down={down} />)}
      </ul>
    </section>
  );
}
