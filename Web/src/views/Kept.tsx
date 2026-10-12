// A prompt or a start kept for a stopped workspace (#691 US3, layouts.md L6): the queued bubble
// of #95, with what it waits for under it and ×, or, once its start failed, why it wasn't sent
// and Try Again. The words are OfflineWords.swift's keptLine.
import type { KeptRequest } from "../protocol/generated";
import type { Store } from "../model/store";

/** What the line under a kept bubble says (OfflineWords.keptLine). */
export function keptLine(name: string, kept: KeptRequest): string {
  return kept.failed ? `Not sent: ${kept.failed}` : `Waiting for ${name} to start`;
}

export function KeptBubbles({ store, kept }: { store: Store; kept: readonly KeptRequest[] }) {
  return (
    <>
      {kept.map((one) => {
        const name = store.hosts.value.find((h) => h.id === one.host)?.name ?? "the host";
        return (
          <div key={one.id} class="queued kept">
            <div class="queued-bubble" role="group" aria-label={`${keptLine(name, one)}: ${one.text}`}>
              <p>{one.text}</p>
            </div>
            <div class="queued-actions">
              <span class={one.failed ? "failure small" : "faint small"}>{keptLine(name, one)}</span>
              {one.failed && <button class="link" onClick={() => void store.retryKept(one)}>Try Again</button>}
              <button class="remove" aria-label="Remove kept prompt" title="Do not send this"
                onClick={() => void store.dropKept(one)}>×</button>
            </div>
          </div>
        );
      })}
    </>
  );
}
