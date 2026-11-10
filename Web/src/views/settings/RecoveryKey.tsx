// Settings ▸ Machines ▸ Recovery key (#4299): whether the person's lock has a recovery key now, and Make Recovery Key,
// also after the sidebar's card was skipped or before it shows (#4248). The key is shown here once, in the card's
// words (#3493, D4). Only while this browser is in its lock. The window's is Settings ▸ Machines ▸ This Mac ▸
// Recovery key (RecoveryKeySettingsSection). Listed in ./sections.ts.
import { useState } from "preact/hooks";
import type { Store } from "../../model/store";

export function RecoveryKeySection({ store, down }: { store: Store; down: boolean }) {
  const lock = store.machineLock;
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);
  if (lock.device.value.kind !== "member") return null;
  const card = lock.recovery.value;
  const has = lock.hasRecovery.value;
  const make = async () => {
    setBusy(true);
    setCopied(false);
    await lock.makeRecoveryKey();
    setBusy(false);
  };
  return (
    <section aria-labelledby="settings-recovery-key">
      <h3 class="section-head" id="settings-recovery-key">Recovery key</h3>
      {card.kind === "show" ? (
        <>
          <div class="setting"><span>Save your recovery key.</span></div>
          <code class="recovery-key">{card.text}</code>
          <p class="hint">Keep it in your password manager. You see it only this once. If you lose every device, it adds a new one.</p>
          <div class="setting">
            <span />
            <span class="recovery-actions">
              <button type="button" onClick={() => void navigator.clipboard?.writeText(card.text).then(() => setCopied(true)).catch(() => {})}>
                {copied ? "Copied" : "Copy"}
              </button>
              <button type="button" class="prominent" onClick={() => lock.recoveryDismissed()}>I Saved It</button>
            </span>
          </div>
        </>
      ) : (
        <>
          <div class="setting">
            <span>{has ? "Your lock has a recovery key." : "Your lock has no recovery key."}</span>
            <button type="button" disabled={down || busy} onClick={() => void make()}>Make Recovery Key</button>
          </div>
          <p class="hint">
            {has
              ? "A new recovery key takes the old one’s place: the old one stops working."
              : "If you lose this device, the recovery key adds your next one. Without it, each machine must join again."}
          </p>
        </>
      )}
    </section>
  );
}
