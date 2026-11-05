// The machine lock's cards (#3490, specs/3399-machine-lock D2), beside the sign-in cards and in
// their look: this browser's own card while it is not in its person's lock, and a card for each
// other device that asks to join, and for each machine that asks (#3491, D3). The words are the
// window's and the Remote's, so the three clients match. A control plane without lock-join/1
// shows nothing.
import { useState } from "preact/hooks";
import type { Store } from "../model/store";
import { brokenWords, newLockWords, type RecoveryCard, type SignerCard, type ThisDevice } from "../model/machineLock";
import { spaced } from "../wire/machineLock";
import { ApprovalMark } from "./Approval";

/**
 * Use Recovery Key on a browser not in its lock (#3493, D4): the person types the key; with none,
 * Start a New Lock. The words are the window's and the Remote's.
 */
function RecoveryForm({ store, down, close }: { store: Store; down: boolean; close: () => void }) {
  const [text, setText] = useState("");
  const [failure, setFailure] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const use = async () => {
    setBusy(true);
    setFailure(await store.machineLock.useRecoveryKey(text));
    setBusy(false);
  };
  const startOver = async () => {
    if (!window.confirm(newLockWords)) return;
    setBusy(true);
    await store.machineLock.startNewLock();
    setBusy(false);
    close();
  };
  return (
    <form class="sign-in-code recovery-form" onSubmit={(e) => { e.preventDefault(); void use(); }}>
      <label for="lock-recovery-key">Type your recovery key.</label>
      <input id="lock-recovery-key" class="recovery-key-field" autocomplete="off" spellcheck={false} placeholder="XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"
        value={text} onInput={(e) => setText(e.currentTarget.value)} />
      {failure && <span class="subtitle" role="alert">{failure}</span>}
      <div class="join-actions">
        <button type="button" disabled={down || busy} onClick={() => void startOver()}>Start a New Lock</button>
        <button type="button" disabled={busy} onClick={close}>Cancel</button>
        <button type="submit" class="prominent" disabled={down || busy || text.trim() === ""}>Use</button>
      </div>
    </form>
  );
}

function OwnCard({ store, device, down }: { store: Store; device: ThisDevice; down: boolean }) {
  const [recovering, setRecovering] = useState(false);
  let title;
  let subtitle = null;
  let action = null;
  switch (device.kind) {
    case "asking":
      title = <>Approve this device on another of your devices.</>;
      subtitle = device.digits
        ? <>Check that the other device shows <code>{spaced(device.digits)}</code>, then approve it there.</>
        : <>Open Agents on a device you use already and choose Compare Digits.</>;
      if (!recovering) action = <button type="button" disabled={down} onClick={() => setRecovering(true)}>Use Recovery Key</button>;
      break;
    case "ended":
      title = device.result === "denied" ? <>This device was not approved.</> : <>Nobody approved this device in time.</>;
      action = (
        <>
          {!recovering && <button type="button" disabled={down} onClick={() => setRecovering(true)}>Use Recovery Key</button>}
          <button type="button" class="prominent" disabled={down} onClick={() => void store.machineLock.askAgain()}>Ask Again</button>
        </>
      );
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
        {recovering && device.kind !== "broken" && <RecoveryForm store={store} down={down} close={() => setRecovering(false)} />}
      </div>
    </li>
  );
}

/**
 * The recovery key on a browser in its lock (#3493, D4): shown once after it is made, to keep in
 * a password manager; or an offer to make one while the lock has only this device.
 */
function RecoveryKeyCard({ store, card, down }: { store: Store; card: RecoveryCard; down: boolean }) {
  const lock = store.machineLock;
  const [copied, setCopied] = useState(false);
  if (card.kind === "none") return null;
  if (card.kind === "offer") {
    return (
      <li class="join-request lock-recovery" aria-label="Make a recovery key">
        <ApprovalMark />
        <div class="body">
          <span class="title">Make a recovery key.</span>
          <span class="subtitle">If you lose this device, the recovery key adds your next one. Without it, each machine must join again.</span>
          <div class="join-actions">
            <button type="button" onClick={() => lock.recoveryDismissed()}>Skip</button>
            <button type="button" class="prominent" disabled={down} onClick={() => void lock.makeRecoveryKey()}>Make Recovery Key</button>
          </div>
        </div>
      </li>
    );
  }
  const copy = () => void navigator.clipboard?.writeText(card.text).then(() => setCopied(true)).catch(() => {});
  return (
    <li class="join-request lock-recovery" aria-label="Save your recovery key">
      <ApprovalMark />
      <div class="body">
        <span class="title">Save your recovery key.</span>
        <code class="recovery-key">{card.text}</code>
        <span class="subtitle">Keep it in your password manager. You see it only this once. If you lose every device, it adds a new one.</span>
        <div class="join-actions">
          <button type="button" onClick={copy}>{copied ? "Copied" : "Copy"}</button>
          <button type="button" onClick={() => lock.recoveryDismissed()}>Skip</button>
          <button type="button" class="prominent" onClick={() => lock.recoveryDismissed()}>I Saved It</button>
        </div>
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
  const machine = request.machine !== undefined;
  switch (view.kind) {
    case "compare":
      title = machine ? <>Approve the new machine <strong>{request.name}</strong>?</> : <><strong>{request.name}</strong> asks to join your devices.</>;
      subtitle = machine
        ? <>Compare the digits with the ones in its log before you approve it.</>
        : <>Compare the digits on both screens before you approve it.</>;
      prominent = <button type="button" class="prominent" disabled={down} onClick={() => void lock.compare(request.request)}>Compare Digits</button>;
      break;
    case "another":
      title = <>Another of your devices is comparing the digits.</>;
      break;
    case "waiting":
      title = <>Waiting for {request.name} to show its digits…</>;
      break;
    case "digits":
      title = machine
        ? <>Approve only if the log of {request.name} shows <code>{spaced(view.digits)}</code>.</>
        : <>Approve only if {request.name} shows <code>{spaced(view.digits)}</code>.</>;
      prominent = <button type="button" class="prominent" disabled={down} onClick={() => void lock.approve(request.request)}>Approve</button>;
      break;
    case "notPromised":
      title = <>{request.name} did not show the digits it promised. Deny it.</>;
      break;
  }
  return (
    <li class="join-request" aria-label={machine ? `The new machine ${request.name} asks to join` : `${request.name} asks to join your devices`}>
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
  const recovery = store.machineLock.recovery.value;
  const own = device.kind === "asking" || device.kind === "ended" || device.kind === "broken";
  if (!own && cards.length === 0 && recovery.kind === "none") return null;
  return (
    <section class="join-requests" aria-label="Devices waiting to join your lock">
      <ul>
        {own && <OwnCard store={store} device={device} down={down} />}
        {device.kind === "member" && <RecoveryKeyCard store={store} card={recovery} down={down} />}
        {cards.map((card) => <RequestCard key={card.request.request} store={store} card={card} down={down} />)}
      </ul>
    </section>
  );
}
