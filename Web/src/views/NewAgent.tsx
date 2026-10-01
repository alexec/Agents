// A new session (071 FR-026): the project's empty pane is the new chat, as in the window (066).
// Where it works (the project folder, a new worktree, or one already there), the runtime, the
// runtime's own menus and the first prompt, started on the project's host with `agents/start`.
// A runtime is started behind the form so its choices are real ones (`agents/options`); a form
// answered from memory is put right by `agents/draftOptions`.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Attachment, ConfigOption, JSONValue, StartRequest, UUID, WorktreeSummary } from "../protocol/generated";
import type { Store } from "../model/store";
import { drawable, modeOption, modeStartsOn, choices, same } from "../model/options";
import { folderKey } from "../model/groups";
import { go } from "../route";
import { Prompt } from "./Prompt";
import { PromptMenus } from "./PromptMenus";

type Where = { kind: "project" } | { kind: "new" } | { kind: "existing"; root: string };

interface Form {
  draftID?: string;
  options: ConfigOption[];
  chosen: Record<string, JSONValue>;
  state: "loading" | "ready" | { failed: string };
}

/** Choices still offered are kept; the rest open on the runtime's current value. */
function keep(options: ConfigOption[], chosen: Record<string, JSONValue>): Record<string, JSONValue> {
  const kept: Record<string, JSONValue> = {};
  for (const option of options) {
    const was = chosen[option.id];
    if (was !== undefined && (option.type === "boolean" || choices(option).some((c) => same(c.value, was)))) kept[option.id] = was;
    else if (option.currentValue !== undefined) kept[option.id] = option.currentValue;
  }
  return kept;
}

export function NewAgent({ store, host, folder, projectName, down }: {
  store: Store; host: string; folder: string; projectName: string; down: boolean;
}) {
  const runtimes = (store.runtimes.value[host] ?? []).filter((r) => "available" in r.availability);
  // Whatever the last session here used, if it can still start; else the first that can (029).
  const recent = (store.agents.value[host] ?? []).filter((a) => runtimes.some((r) => r.runtime.id === a.runtimeID))
    .sort((a, b) => b.lastActivityAt - a.lastActivityAt)[0]?.runtimeID;
  const runtimeID = useSignal<string | undefined>(undefined);
  const chosenRuntime = runtimeID.value ?? recent ?? runtimes[0]?.runtime.id;
  const where = useSignal<Where>({ kind: "project" });
  const worktrees = useSignal<WorktreeSummary[]>([]);
  const canMakeNew = useSignal(false);
  const form = useSignal<Form>({ options: [], chosen: {}, state: "loading" });

  useEffect(() => {
    // What each runtime takes changes once it has run: asked again as the form opens.
    void store.loadRuntimes(host);
    where.value = { kind: "project" };
    void store.worktrees(host, folder).then((list) => {
      worktrees.value = (list?.worktrees ?? []).filter((w) => !w.isProjectFolder && w.exists);
      canMakeNew.value = list?.canMakeNew ?? false;
    });
  }, [host, folder]);

  // A draft runtime for the folder it will work in, asked again when either changes.
  const cwd = where.value.kind === "existing" ? where.value.root : folder;
  useEffect(() => {
    if (!chosenRuntime) return;
    let current = true;
    form.value = { options: [], chosen: {}, state: "loading" };
    void store.draft(host, chosenRuntime, cwd).then((answer) => {
      if (!current) {
        if ("draftID" in answer) store.discardDraft(host, answer.draftID);
        return;
      }
      if ("failure" in answer) {
        form.value = { options: [], chosen: {}, state: { failed: answer.failure } };
        return;
      }
      const options = drawable(undefined, answer.options);
      const chosen = keep(options, {});
      const mode = modeOption(options);
      const value = mode ? modeStartsOn(store.rememberedModes.value[host]?.[chosenRuntime], mode) : undefined;
      if (mode && value !== undefined) chosen[mode.id] = value;
      form.value = { draftID: answer.draftID, options, chosen, state: "ready" };
    });
    return () => {
      current = false;
      const draft = form.peek().draftID;
      if (draft) store.discardDraft(host, draft);
    };
  }, [host, chosenRuntime, cwd]);

  // The correction to a form answered from memory.
  const correction = store.draftOptions.value;
  useEffect(() => {
    if (!correction || correction.draftID !== form.peek().draftID) return;
    if (correction.failure) {
      form.value = { options: [], chosen: {}, state: { failed: correction.failure } };
      return;
    }
    const options = drawable(undefined, correction.options);
    form.value = { ...form.peek(), options, chosen: keep(options, form.peek().chosen), state: "ready" };
  }, [correction]);

  const capabilities = chosenRuntime ? store.account(host, chosenRuntime)?.promptCapabilities : undefined;

  const start = async (text: string, attachments: Attachment[]) => {
    if (!chosenRuntime) {
      store.problem.value = "Choose a runtime to start.";
      return false;
    }
    const w = where.value;
    const request: StartRequest = {
      runtimeID: chosenRuntime, cwd: folder as never, prompt: text, attachments,
      startOptions: { values: form.value.chosen, extraArguments: [] },
      ...(form.value.draftID ? { draftID: form.value.draftID as UUID } : {}),
      additionalDirectories: [], mcpServers: [], labels: [],
      ...(w.kind === "new" ? { worktree: { new: {} } } : w.kind === "existing" ? { worktree: { existing: { _0: w.root as never } } } : {}),
      requestID: crypto.randomUUID().toUpperCase() as UUID,
    };
    const id = await store.start(host, request);
    if (!id) return false;
    // The runtime behind the form is the agent's now.
    const { draftID: _taken, ...rest } = form.value;
    form.value = rest;
    go({ host, project: folder, session: id });
    return true;
  };

  const state = form.value.state;
  return (
    <section class="chat new-agent" aria-label="New session">
      <header class="column-head">
        <button class="back narrow-only" onClick={() => go({ host, project: folder })}>‹ {projectName}</button>
        <h1>New session in {projectName}</h1>
      </header>
      <div class="scroll new-form">
        <label class="field">
          <span class="quiet small">Works in</span>
          <select aria-label="Works in" value={where.value.kind === "existing" ? `existing:${where.value.root}` : where.value.kind}
            onChange={(e) => {
              const v = (e.currentTarget as HTMLSelectElement).value;
              where.value = v === "project" ? { kind: "project" } : v === "new" ? { kind: "new" } : { kind: "existing", root: v.slice(9) };
            }}>
            <option value="project">The project folder</option>
            {canMakeNew.value && <option value="new">A new worktree</option>}
            {worktrees.value.map((w) => (
              <option key={w.root} value={`existing:${w.root}`}>Worktree {w.name}{w.branch ? ` (${w.branch})` : ""}</option>
            ))}
          </select>
        </label>
        <label class="field">
          <span class="quiet small">Runtime</span>
          <select aria-label="Runtime" value={chosenRuntime ?? ""} disabled={!runtimes.length}
            onChange={(e) => (runtimeID.value = (e.currentTarget as HTMLSelectElement).value)}>
            {!runtimes.length && <option value="">No runtime can start on this host</option>}
            {runtimes.map((r) => <option key={r.runtime.id} value={r.runtime.id}>{r.runtime.name}</option>)}
          </select>
        </label>
        {state === "loading" && chosenRuntime && <p class="quiet small">Asking {runtimes.find((r) => r.runtime.id === chosenRuntime)?.runtime.name ?? "the runtime"} what it offers…</p>}
        {typeof state === "object" && <p class="failure small">{state.failed}</p>}
        {state === "ready" && !form.value.options.length && <p class="quiet small">This runtime has no settings to choose.</p>}
        <p class="hint">Say what you want done. It starts on {folderKey(folder).split("/").pop()}{where.value.kind === "new" ? ", in a new worktree" : ""}.</p>
      </div>
      <footer class="foot">
        <Prompt store={store} draftKey={`new|${host}|${folderKey(folder)}`} placeholder="What should it do?"
          capabilities={capabilities} disabled={down || !chosenRuntime} send={start}>
          <PromptMenus options={form.value.options} value={(o) => form.value.chosen[o.id]}
            onChange={(o, v) => (form.value = { ...form.value, chosen: { ...form.value.chosen, [o.id]: v } })} disabled={down} />
        </Prompt>
      </footer>
    </section>
  );
}
