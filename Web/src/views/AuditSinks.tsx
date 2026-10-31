// Console ▸ Audit ▸ Sinks (#1001): an admin's places that get each audit entry as it is written.
// Shown only when the control plane answers audit/sinks: an admin's, on a control plane that has them.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { AuditSinkKind, AuditSinkStatus } from "../protocol/generated";
import { addressPlaceholder, draftsOf, type SinkDraft, sinksHint, sinksMost, sinksToSet, sinkStatusLine } from "../model/auditSinks";
import { describe } from "../model/errors";

export function AuditSinks({ store, down }: { store: Store; down: boolean }) {
  const state = useSignal<AuditSinkStatus[] | null>(null);
  const drafts = useSignal<SinkDraft[]>([]);
  const problem = useSignal<string | null>(null);
  const saving = useSignal(false);
  const take = (sinks: AuditSinkStatus[]) => {
    state.value = sinks;
    drafts.value = draftsOf(sinks);
  };
  useEffect(() => {
    if (down) return;
    // A member, or a control plane from before sinks, answers with an error: no section.
    void store.link.call("audit/sinks", {}).then((s) => take(s.sinks), () => { state.value = null; });
  }, [down]);
  if (state.value === null) return null;
  const change = (i: number, edit: Partial<SinkDraft>) => {
    drafts.value = drafts.value.map((d, at) => (at === i ? { ...d, ...edit } : d));
  };
  const save = async () => {
    saving.value = true;
    try {
      take((await store.link.call("audit/setSinks", { sinks: sinksToSet(drafts.value) })).sinks);
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    } finally {
      saving.value = false;
    }
  };
  const status = (address: string) => state.value?.find((s) => s.sink.address === address.trim());
  return (
    <section class="audit-sinks">
      <h3>Sinks</h3>
      <p class="quiet small">{sinksHint}</p>
      {drafts.value.map((d, i) => {
        const now = status(d.address);
        return (
          <div class="audit-sink" key={i}>
            <select aria-label="Kind" value={d.kind} disabled={down}
              onChange={(e) => change(i, { kind: (e.currentTarget as HTMLSelectElement).value as AuditSinkKind })}>
              <option value="syslog">Syslog</option>
              <option value="http">HTTP</option>
            </select>
            <input aria-label="Address" placeholder={addressPlaceholder(d.kind)} value={d.address} disabled={down}
              onInput={(e) => change(i, { address: (e.currentTarget as HTMLInputElement).value })} />
            {d.kind === "http" && (
              <input aria-label="Token" type="password" autocomplete="off" disabled={down}
                placeholder={d.hasToken ? "Token kept" : "Token (optional)"} value={d.token}
                onInput={(e) => change(i, { token: (e.currentTarget as HTMLInputElement).value })} />
            )}
            <button class="link" disabled={down} title="Stop sending to this sink"
              onClick={() => { drafts.value = drafts.value.filter((_, at) => at !== i); }}>Remove</button>
            {now && <p class="quiet small">{sinkStatusLine(now)}</p>}
          </div>
        );
      })}
      <div class="audit-sinks-foot">
        <button disabled={down || drafts.value.length >= sinksMost} title={`At most ${sinksMost} sinks`}
          onClick={() => { drafts.value = [...drafts.value, { kind: "syslog", address: "", token: "", hasToken: false }]; }}>Add Sink</button>
        <button disabled={down || saving.value} onClick={() => void save()}>Save</button>
      </div>
      {problem.value && <p class="hint">{problem.value}</p>}
    </section>
  );
}
