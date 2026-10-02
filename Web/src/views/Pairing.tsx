// Frame E: with no key, the page shows this and nothing else (071 US1). A code is pasted,
// or arrives in the address from Open in Browser (#109, pairLink.ts).
import { useSignal } from "@preact/signals";
import type { Session } from "../session";

export function Pairing({ session }: { session: Session }) {
  const code = useSignal("");
  const busy = session.state.value.kind === "pairing";
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
        <h1>Connect this browser to your agents</h1>
        <p>
          Get a code from Agents on this Mac: in the window,{" "}
          <strong>Settings ▸ Control plane ▸ Clients ▸ Pair a Browser…</strong>, or in Agents Host,{" "}
          <strong>Pair a Window or Phone…</strong>. Paste it here.
        </p>
        <textarea
          aria-label="Code"
          placeholder="agents-control:2:c:device:…"
          spellcheck={false}
          autocomplete="off"
          autoFocus
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
