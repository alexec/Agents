// Frame E: with no key, the page shows this and nothing else (071 US1). A code is pasted,
// or arrives in the address from Open in Browser (#109, pairLink.ts). On the control plane's own
// domain, its organisation's providers come first (#1002, FR-026): a button each, then Use an
// Email when a claimed domain sends people to one, then Sign in with your account when a built-in
// provider is on (#2097: approval on one of the person's clients), then the code.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import { askFoot, askPlaceholder, askTitle, askWaiting, emailPlaceholder, looksLikeEmail, orgButton, required, suspendedFoot,
  suspendedFootUnpaired, suspendedLine, useEmail } from "../model/signIn";
import { onThisMac } from "../place";
import type { Session } from "../session";
import { Huddle } from "./Huddle";

/** The org providers' buttons, and Use an Email (FR-026, FR-011). Nothing when there are none. */
function OrgSignIn({ session, busy }: { session: Session; busy: boolean }) {
  const emailOpen = useSignal(false);
  const email = useSignal("");
  const finding = useSignal(false);
  const wanted = session.orgRequired.value;
  const providers = session.orgProviders.value;
  // The provider a refusal asked for comes first, also when the list did not load.
  const shown = wanted ? [wanted, ...providers.filter((p) => p.id !== wanted.id)] : providers;
  if (shown.length === 0) return null;
  const waiting = busy || session.orgBusy.value || finding.value;
  const findByEmail = async () => {
    if (waiting || !looksLikeEmail(email.value)) return;
    finding.value = true;
    try {
      const provider = await session.discoverEmail(email.value);
      if (provider) await session.startOrg(provider.id, email.value.trim());
    } finally {
      finding.value = false;
    }
  };
  return (
    <div class="pairing-org">
      {wanted && <p class="pairing-required" role="alert">{required(wanted.name)}</p>}
      {shown.map((provider) => (
        <button key={provider.id} type="button" class="prominent" disabled={waiting}
          onClick={() => void session.startOrg(provider.id)}>{orgButton(provider.name)}</button>
      ))}
      {session.discover.value && !emailOpen.value && (
        <button type="button" disabled={waiting} onClick={() => { emailOpen.value = true; }}>{useEmail}</button>
      )}
      {session.discover.value && emailOpen.value && (
        <div class="pairing-email">
          <input type="email" aria-label="Email" placeholder={emailPlaceholder} autocomplete="email" autoFocus
            value={email.value} onInput={(e) => (email.value = (e.currentTarget as HTMLInputElement).value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                void findByEmail();
              }
            }} />
          <button type="button" disabled={waiting || !looksLikeEmail(email.value)} onClick={() => void findByEmail()}>Continue</button>
        </div>
      )}
    </div>
  );
}

/**
 * Sign in with your account (#2097): an email or GitHub login, then the code to type on one of the
 * person's signed-in clients while the page waits. Nothing when no built-in provider is on.
 */
function AskSignIn({ session, busy }: { session: Session; busy: boolean }) {
  const account = useSignal("");
  const going = useSignal(false);
  if (!session.askOn.value) return null;
  const code = session.askCode.value;
  const ask = async () => {
    if (busy || going.value || !account.value.trim()) return;
    going.value = true;
    try {
      await session.askToPair(account.value);
    } finally {
      going.value = false;
    }
  };
  if (going.value) {
    return (
      <div class="pairing-ask" role="status">
        {code ? (
          <>
            <p>{askWaiting}</p>
            <p class="pairing-ask-code"><code>{code}</code></p>
          </>
        ) : <p>Asking…</p>}
        <div class="pairing-actions">
          <button type="button" onClick={() => session.cancelAsk()}>Cancel</button>
        </div>
      </div>
    );
  }
  return (
    <div class="pairing-ask">
      <h2>{askTitle}</h2>
      <div class="pairing-email">
        <input type="text" aria-label={askPlaceholder} placeholder={askPlaceholder} autocomplete="username" spellcheck={false}
          value={account.value} onInput={(e) => (account.value = (e.currentTarget as HTMLInputElement).value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              void ask();
            }
          }} />
        <button type="button" disabled={busy || !account.value.trim()} onClick={() => void ask()}>Continue</button>
      </div>
      <p class="pairing-note">{askFoot}</p>
    </div>
  );
}

export function Pairing({ session }: { session: Session }) {
  const code = useSignal("");
  const busy = session.state.value.kind === "pairing";
  // The org providers, read once on a short sign-in connection; none on this Mac's page.
  useEffect(() => void session.loadOrgProviders(), []);
  const org = session.orgProviders.value.length > 0 || session.orgRequired.value !== null || session.askOn.value;
  const submit = (event: Event) => {
    event.preventDefault();
    if (!busy && code.value.trim()) void session.pair(code.value);
  };
  return (
    <main class="pairing">
      <form class="pairing-card" onSubmit={submit}>
        {session.wasForgotten.value && (
          <p class="pairing-forgotten" role="status">This browser was forgotten. Pair it again to carry on.</p>
        )}
        {/* The mark of a team (#1007): no prompt here, so the Blobs only look around. */}
        <Huddle focused={false} typed={0} />
        <h1>Connect this browser to your agents</h1>
        <OrgSignIn session={session} busy={busy} />
        <AskSignIn session={session} busy={busy} />
        {onThisMac() ? (
          <p>
            Get a code from Agents on this Mac: in the window,{" "}
            <strong>Settings ▸ Control plane ▸ Clients ▸ Add a Browser…</strong>, or in Agents Host,{" "}
            <strong>Pair a Window or Phone… ▸ A browser on this Mac</strong>. Paste it here.
          </p>
        ) : (
          // The page on the control plane's own domain (#1459): any paired window or phone makes one.
          <p>
            {org && "Or pair with a code. "}
            Get a code from Agents where it is already connected: on a Mac,{" "}
            <strong>Settings ▸ Control plane ▸ Clients ▸ Add a Browser…</strong>; on an iPhone or iPad,{" "}
            <strong>Add a Browser…</strong> at the foot of the sidebar. Paste it here.
          </p>
        )}
        <textarea
          aria-label="Code"
          placeholder="agents-control:2:c:…"
          spellcheck={false}
          autocomplete="off"
          autoFocus={!org}
          value={code.value}
          onInput={(event) => (code.value = (event.currentTarget as HTMLTextAreaElement).value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !event.shiftKey) submit(event);
          }}
        />
        <div class="pairing-actions">
          <button type="submit" class="prominent" disabled={busy || !code.value.trim()}>
            {busy ? "Connecting…" : "Connect"}
          </button>
        </div>
        {session.pairingError.value && (
          <p class="pairing-error" role="alert">{session.pairingError.value}</p>
        )}
        <p class="pairing-note">
          This browser keeps a key of its own, which can't be copied out of it. Clearing this site's data, or closing a
          private window, loses it, and you pair again.
        </p>
      </form>
    </main>
  );
}

/** A browser that can't keep a key safely (spec edge case): no pairing at all. */
export function Unsupported() {
  return (
    <main class="pairing">
      <div class="pairing-card">
        <h1>This browser isn't supported</h1>
        <p>
          It can't keep a key that can't be copied out of it, which is how Agents knows it's you. Use the current Safari or
          Chrome.
        </p>
      </div>
    </main>
  );
}

/** The control plane on this port isn't the one this browser paired with. */
export function OtherControlPlane({ session }: { session: Session }) {
  return (
    <main class="pairing">
      <div class="pairing-card">
        <h1>This isn't the control plane this browser paired with</h1>
        <p>Something else now answers here, with a key of its own. Pair this browser with it to carry on.</p>
        <div class="pairing-actions">
          <button class="prominent" onClick={async () => {
            await session.keys.forget();
            session.state.value = { kind: "unpaired" };
          }}>Pair Again</button>
        </div>
      </div>
    </main>
  );
}

/**
 * A client of a suspended person (#1002, FR-029): this page and no other. A paired browser keeps
 * its key and connects again by itself when the organisation turns its access on.
 */
export function Suspended({ paired }: { paired: boolean }) {
  return (
    <main class="pairing">
      <div class="pairing-card" role="status">
        <h1>{suspendedLine}</h1>
        <p>{paired ? suspendedFoot : suspendedFootUnpaired}</p>
      </div>
    </main>
  );
}
