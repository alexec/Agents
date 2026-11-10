// Settings ▸ Control plane ▸ Clients (#4253), as the window's: Pair a Device… shows a QR code for the Remote to
// scan, and Pair a Mac… and Add a Browser… a code to paste. Each code is made when its dialog opens and works once;
// the dialog names the client it let in. Listed in ./sections.ts.
import { useEffect, useState } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { ClientRecord, ControlCodeShown } from "../../protocol/generated";
import { fromWireDate } from "../../protocol/dates";
import { describe } from "../../model/errors";
import { codeInstructions, type PairPurpose, pairPurposes, pairWords as words, qrModules, remainingLine } from "../../model/pairClients";
import type { Store } from "../../model/store";
import { Modal } from "../Modal";

export function ClientsSection({ store, down }: { store: Store; down: boolean }) {
  const [pairing, setPairing] = useState<PairPurpose | null>(null);
  return (
    <section aria-labelledby="settings-clients">
      <h3 class="section-head" id="settings-clients">{words.heading}</h3>
      <div class="pair-buttons">
        {pairPurposes.map((purpose) => (
          <button key={purpose} type="button" disabled={down} onClick={() => setPairing(purpose)}>{words.button(purpose)}</button>
        ))}
      </div>
      <p class="hint">{words.hint}</p>
      {pairing && <PairDialog store={store} purpose={pairing} close={() => setPairing(null)} />}
    </section>
  );
}

function PairDialog({ store, purpose, close }: { store: Store; purpose: PairPurpose; close: () => void }) {
  const shown = useSignal<ControlCodeShown | null>(null);
  const problem = useSignal<string | null>(null);
  const copied = useSignal(false);
  const before = useSignal<Set<string> | null>(null);
  const joined = useSignal<ClientRecord | null>(null);
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    // Who was there first, so whoever the code lets in can be named.
    store.link.call("clients/list", {})
      .then((clients) => { before.value = new Set(clients.map((c) => c.id)); })
      .then(() => store.link.call("clients/startPairing", purpose === "browser" ? { kind: "browser" } : {}))
      .then((code) => { shown.value = code; })
      .catch((error) => { problem.value = describe(error); });
    const tick = setInterval(() => setNow(Date.now()), 1000);
    return () => {
      clearInterval(tick);
      void store.link.call("clients/stopPairing", {}).catch(() => {});
    };
  }, []);
  const changes = store.clientChanges.value;
  useEffect(() => {
    const was = before.value;
    if (!was || !shown.value || joined.value) return;
    store.link.call("clients/list", {})
      .then((clients) => { joined.value = clients.find((c) => !was.has(c.id) && !c.forgotten) ?? null; })
      .catch(() => {});
  }, [changes]);
  const code = shown.value;
  const expires = code ? fromWireDate(code.expires).getTime() : 0;
  const copy = () => {
    if (code) void navigator.clipboard?.writeText(code.text).then(() => { copied.value = true; }).catch(() => {});
  };
  const title = words.title(purpose);
  const plane = store.plane.value;
  return (
    <Modal label={title} close={close}>
      <div class="sheet-body invite-code">
        <h2>{title}</h2>
        {joined.value ? (
          purpose === "device" ? (
            <>
              <p class="sheet-note" role="status">{words.paired(joined.value.name)}</p>
              <p class="sheet-note">{words.pairedNote}</p>
            </>
          ) : <p class="sheet-note" role="status">{words.joined(joined.value.name)}</p>
        ) : code ? (
          purpose === "device" ? (
            <>
              <p class="sheet-note">{words.scan}</p>
              <QRCode text={code.text} />
              <p class="sheet-note quiet" aria-live="off">{remainingLine(expires, now)}</p>
            </>
          ) : (
            <>
              <code class="code-text" aria-label="Code">{code.text}</code>
              <p class="sheet-note">{codeInstructions(purpose, expires, now, plane?.web, plane?.publicWeb)}</p>
            </>
          )
        ) : !problem.value && <p class="sheet-note" role="status">{words.making}</p>}
        {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
        <div class="sheet-actions">
          {code && !joined.value && purpose !== "device" && (
            <button type="button" onClick={copy}>{copied.value ? "Copied" : "Copy"}</button>
          )}
          <button type="button" class="prominent" onClick={close}>{joined.value || purpose !== "device" ? "Done" : "Cancel"}</button>
        </div>
      </div>
    </Modal>
  );
}

/** A QR code, dark on light whatever the theme, sharp at any size: one square per module. */
function QRCode({ text }: { text: string }) {
  const { size, dark } = qrModules(text);
  return (
    <svg class="pair-qr" viewBox={`0 0 ${size} ${size}`} role="img" aria-label="Pairing code" shape-rendering="crispEdges">
      <rect width={size} height={size} fill="white" />
      <path fill="black" d={dark.map(([x, y]) => `M${x} ${y}h1v1h-1z`).join("")} />
    </svg>
  );
}
