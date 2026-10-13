// A new session (071 FR-026): the project's empty pane is the new chat, as in the window (066):
// the project's name and folder in the middle, and the prompt bar at the foot (#108). Over the
// input, where it works (the project folder, a new worktree, or one already there), what else it
// may reach and its labels on the left, and the runtime on the right; under it, the runtime's own
// menus. Started on the project's host with `agents/start`. A runtime is started behind the bar
// so its choices are real ones (`agents/options`); a bar answered from memory is put right by
// `agents/draftOptions`.
//
// As the window's bar (#257): where it works offers every worktree, a missing one greyed, a new
// one on a branch, and why a new one can't be made; the runtimes come in Available and Out runs,
// with those that cannot start greyed with why; the sandbox is chosen beside them, and a sandbox
// that will not start offers Start without sandbox; options that failed to load can be asked for
// again; and the form's runtime, choices and reach are kept between starts.
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { Attachment, BranchSummary, ConfigOption, JSONValue, Persona, RuntimeStatus, SandboxChoice, SlashCommand, StartRequest, UUID, WorktreeSize,
  WorktreeSummary } from "../protocol/generated";
import type { SandboxWillNotStart, Store } from "../model/store";
import { drawable, modeOption, modeStartsOn, choices, same } from "../model/options";
import { folderKey } from "../model/groups";
import { formRuntime, newSessionRuntime, runtimeRuns, unavailableReason } from "../model/runtimes";
import { formFor, keepForm, keptForm } from "../model/startForm";
import { personaChoices, withPersonaLabels } from "../model/personas";
import { chatProject } from "../model/chat";
import { sandboxCardTitle, sandboxChoiceWords, sandboxChoices, sandboxExplanation, sandboxOverrideWords, sandboxState,
  sandboxStateWords, sandboxWhy, startWithout } from "../model/sandbox";
import { accepted } from "../model/labels";
import type { Start } from "./chat/appViewBridge";
import { go } from "../route";
import { sizeWords } from "../model/worktrees";
import { LabelField } from "./Labels";
import { Reach } from "./Reach";
import { Prompt } from "./Prompt";
import { OfflineStrip } from "./OfflineStrip";
import { PromptMenus } from "./PromptMenus";
import { BackToList } from "./BackToList";
import { orderedProjects, projectLabel } from "./Sidebar";
import { GuardedChangeCards } from "./GuardedChange";
import { KeptBubbles } from "./Kept";

type Where = { kind: "project" } | { kind: "new" } | { kind: "existing"; root: string } | { kind: "branch"; name: string }
  | { kind: "named"; name: string };

const storage = typeof localStorage === "undefined" ? undefined : localStorage;

interface Form {
  draftID?: string;
  options: ConfigOption[];
  /** What the draft runtime takes after a slash (#255). */
  commands?: SlashCommand[];
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
  const listed = store.runtimes.value[host] ?? [];
  const runs = runtimeRuns(listed);
  const runtimes = [...runs.available, ...runs.out];
  // The form as it was left, its runtime only while that can still start (DraftKeeper).
  const kept = useSignal(keptForm(storage));
  const startable = runtimes.map((r) => r.runtime.id);
  const left = formFor(kept.value, startable);
  const runtimeID = useSignal<string | undefined>(undefined);
  // The one rule (#264), frozen when the form opens (#291): a later listing, or another agent's
  // activity, does not move it and so does not discard the draft runtime and start another.
  const openedRuntime = useRef<{ host: string; folder: string; runtimeID?: string }>({ host, folder });
  if (openedRuntime.current.host !== host || openedRuntime.current.folder !== folder) openedRuntime.current = { host, folder };
  if (openedRuntime.current.runtimeID === undefined) {
    const opening = newSessionRuntime(left.runtimeID, startable);
    if (opening !== undefined) openedRuntime.current = { host, folder, runtimeID: opening };
  }
  // A runtime picked here counts only while this host offers it: the bar can move to another host.
  const picked = runtimeID.value !== undefined && startable.includes(runtimeID.value) ? runtimeID.value : undefined;
  const chosenRuntime = formRuntime(openedRuntime.current.runtimeID, picked, startable, left.runtimeID);
  const where = useSignal<Where>({ kind: "project" });
  const worktrees = useSignal<WorktreeSummary[]>([]);
  const branches = useSignal<BranchSummary[]>([]);
  const canMakeNew = useSignal(false);
  const whyNot = useSignal<string | undefined>(undefined);
  const isRepository = useSignal(false);
  const folders = useSignal<string[]>(left.folders);
  const labels = useSignal<string[]>([]);
  const form = useSignal<Form>({ options: [], chosen: {}, state: "loading" });
  /** This session's own sandbox; none follows the runtime's default. */
  const sandbox = useSignal<SandboxChoice | undefined>(undefined);
  const refusal = useSignal<SandboxWillNotStart | null>(null);
  /** What was last sent, for Start without sandbox to send again. */
  const lastSent = useRef<{ text: string; attachments: Attachment[] } | null>(null);
  /** The kept starts this page has shown: the one that reaches its host opens here (#691 US3). */
  const keptShown = useRef(new Set<string>());
  /** Asked again by Try again. */
  const asking = useSignal(0);
  /** The project's personas (#760), the one picked by id, and one picked before its runtime's menus came. */
  const personas = useSignal<Persona[]>([]);
  const persona = useSignal<string | undefined>(undefined);
  const pendingPersona = useRef<Persona | undefined>(undefined);
  /** A new worktree a view named (#834), or a branch it named (#837), made the place once the folder is
   *  known to be a repository. */
  const offeredWorktree = useRef<Where | undefined>(undefined);
  /** The project whose worktrees are listed, so an offer knows whether it can be placed now. */
  const listedFor = useRef("");
  /** Counts the offers taken: the prompt field opens afresh on each, with the view's words. */
  const filled = useSignal(0);
  const placeOffered = () => {
    const offered = offeredWorktree.current;
    offeredWorktree.current = undefined;
    if (offered && isRepository.peek()) where.value = offered;
  };

  useEffect(() => {
    // What each runtime takes changes once it has run: asked again as the form opens.
    void store.loadRuntimes(host);
    where.value = { kind: "project" };
    folders.value = keptForm(storage).folders;
    labels.value = [];
    offeredWorktree.current = undefined;
    listedFor.current = "";
    refusal.value = null;
    persona.value = undefined;
    pendingPersona.current = undefined;
    personas.value = [];
    void store.personas(host, folder).then((list) => (personas.value = list));
    void store.worktrees(host, folder).then((list) => {
      worktrees.value = (list?.worktrees ?? []).filter((w) => !w.isProjectFolder);
      branches.value = list?.branches ?? [];
      canMakeNew.value = list?.canMakeNew ?? false;
      whyNot.value = list?.whyNot;
      isRepository.value = list?.isRepository ?? false;
      listedFor.current = `${host}|${folderKey(folder)}`;
      placeOffered();
    });
  }, [host, folder]);

  // The form moved: kept, as the window's noteStartForm.
  const note = (change: Partial<{ runtimeID: string; chosen: Record<string, JSONValue>; folders: string[] }>) => {
    const next = { ...kept.peek(), ...change };
    kept.value = next;
    keepForm(storage, next);
  };

  // A view's agents/start-agent (#834): the form filled in, and nothing started. The person
  // presses Start, or doesn't. A folder that is not a repository keeps its place.
  const offered = store.offeredStart.value;
  const draftKey = `new|${host}|${folderKey(folder)}`;
  useEffect(() => {
    if (!offered || offered.host !== host || folderKey(offered.folder) !== folderKey(folder)) return;
    store.offeredStart.value = null;
    store.drafts.set(draftKey, { text: offered.start.prompt, attachments: [] });
    filled.value += 1;
    // Added to those on the form, held to what a session takes, as a label typed here is.
    labels.value = [...labels.value, ...accepted(offered.start.labels, labels.value)];
    offeredWorktree.current = offered.start.branch ? { kind: "branch", name: offered.start.branch }
      : offered.start.worktree ? { kind: "named", name: offered.start.worktree } : undefined;
    if (listedFor.current === `${host}|${folderKey(folder)}`) placeOffered();
  }, [offered, host, folder]);

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
      const mode = modeOption(options);
      const value = mode ? modeStartsOn(store.rememberedModes.value[host]?.[chosenRuntime], mode) : undefined;
      // The choices left on this runtime, where they are still choices; the mode remembered otherwise.
      const left = kept.peek().runtimeID === chosenRuntime ? kept.peek().chosen : {};
      let chosen = keep(options, mode && value !== undefined && left[mode.id] === undefined ? { ...left, [mode.id]: value } : left);
      // Over the mode remembered, because the persona was picked after it (#760).
      const waiting = pendingPersona.current;
      if (waiting && options.length) {
        chosen = { ...chosen, ...personaChoices(waiting, options) };
        pendingPersona.current = undefined;
      }
      form.value = { draftID: answer.draftID, options, commands: answer.commands, chosen, state: "ready" };
    });
    return () => {
      current = false;
      const draft = form.peek().draftID;
      if (draft) store.discardDraft(host, draft);
    };
  }, [host, chosenRuntime, cwd, asking.value]);

  // The correction to a form answered from memory.
  const correction = store.draftOptions.value;
  useEffect(() => {
    if (!correction || correction.draftID !== form.peek().draftID) return;
    if (correction.failure) {
      form.value = { options: [], chosen: {}, state: { failed: correction.failure } };
      return;
    }
    const options = drawable(undefined, correction.options);
    form.value = { ...form.peek(), options, commands: correction.commands, chosen: keep(options, form.peek().chosen), state: "ready" };
  }, [correction]);

  // Pick a kind of session (#760): what it names is set, what it leaves out stays as the form has it.
  const choosePersona = (id: string) => {
    const picked = personas.value.find((p) => p.id === id && p.problem === undefined);
    persona.value = picked?.id;
    pendingPersona.current = undefined;
    if (!picked) return;
    labels.value = withPersonaLabels(labels.value, picked);
    const wanted = picked.settings.runtimeID;
    if (wanted !== undefined && wanted !== chosenRuntime && runs.available.some((r) => r.runtime.id === wanted)) {
      pendingPersona.current = picked;
      runtimeID.value = wanted;
      sandbox.value = undefined;
      refusal.value = null;
      return;
    }
    if (form.value.state !== "ready") pendingPersona.current = picked;
    else form.value = { ...form.value, chosen: { ...form.value.chosen, ...personaChoices(picked, form.value.options) } };
  };
  const usablePersonas = personas.value.filter((p) => p.problem === undefined);
  const brokenPersonas = personas.value.filter((p) => p.problem !== undefined);
  const chat = chatProject(store.projects.value[host]);
  const isChatProject = chat !== undefined && folderKey(chat.project.folder) === folderKey(folder);
  const description = usablePersonas.find((p) => p.id === persona.value)?.description;

  const capabilities = chosenRuntime ? store.account(host, chosenRuntime)?.promptCapabilities : undefined;

  const start = async (text: string, attachments: Attachment[], override = sandbox.value) => {
    if (!chosenRuntime) {
      store.say("Choose a runtime to start.");
      return false;
    }
    lastSent.current = { text, attachments };
    refusal.value = null;
    const w = where.value;
    const request: StartRequest = {
      runtimeID: chosenRuntime, cwd: folder as never, prompt: text, attachments,
      startOptions: { values: form.value.chosen, extraArguments: [] },
      ...(form.value.draftID ? { draftID: form.value.draftID as UUID } : {}),
      additionalDirectories: folders.value as never[], mcpServers: [], labels: labels.value,
      ...(w.kind === "new" ? { worktree: { new: {} } } : w.kind === "existing" ? { worktree: { existing: { _0: w.root as never } } }
        : w.kind === "branch" ? { worktree: { branch: { _0: w.name } } } : w.kind === "named" ? { worktree: { named: { _0: w.name } } } : {}),
      ...(override ? { sandbox: override } : {}),
      ...(persona.value ? { persona: persona.value } : {}),
      // Kept until this start succeeds, so a retry after a timeout is the same start (#291).
      requestID: store.startRequestID(host, folder),
    };
    const id = await store.start(host, request);
    if (!id) return false;
    // Kept for a stopped workspace (#691 US3): shown here until the agent it makes opens.
    if (typeof id === "object" && "kept" in id) {
      store.finishStartRequest(host, folder);
      return true;
    }
    if (typeof id === "object") {
      refusal.value = id;
      return false;
    }
    store.finishStartRequest(host, folder);
    note({ runtimeID: chosenRuntime, chosen: form.value.chosen, folders: folders.value });
    sandbox.value = undefined;
    // The runtime behind the form is the agent's now.
    const { draftID: _taken, ...rest } = form.value;
    form.value = rest;
    go({ host, project: folder, session: id });
    return true;
  };

  // Starts kept for this project's stopped workspace; the one that reaches it opens (#691 US3).
  const keptStarts = store.keptStarts(host, folder);
  const delivered = store.keptDelivered.value;
  useEffect(() => {
    if (delivered?.agentID && delivered.host === host && keptShown.current.has(delivered.id)) {
      go({ host, project: folder, session: delivered.agentID });
    }
  }, [delivered]);
  useEffect(() => { for (const k of keptStarts) keptShown.current.add(k.id); }, [keptStarts]);

  const state = form.value.state;
  const runtimeName = listed.find((r) => r.runtime.id === chosenRuntime)?.runtime.name ?? "the runtime";
  /** Under a runtime's name: its pool note, else whether it is signed in (the window's signInNote). */
  const runtimeNote = (r: RuntimeStatus) => {
    if (r.poolNote) return r.poolNote;
    const account = store.account(host, r.runtime.id);
    return account?.state === "needsSignIn" ? "Needs signing in" : account?.signedInAs?.label;
  };
  const runtimeOption = (r: RuntimeStatus) => {
    const said = unavailableReason(r) ?? runtimeNote(r);
    return <option key={r.runtime.id} value={r.runtime.id} disabled={!("available" in r.availability)} title={said ?? ""}>
      {r.runtime.name}{said ? ` — ${said}` : ""}</option>;
  };
  // Codex's sandbox is its mode (FR-005a), so its state is read off the mode chosen.
  const modeID = form.value.options.find((o) => o.id === "mode")?.id;
  const codexMode = modeID ? form.value.chosen[modeID] : undefined;
  const runtimeDefault = (chosenRuntime && store.sandboxDefaults.value[host]?.[chosenRuntime]) || "runtime";
  // Where the runtime stands in the pool when it, or one of its models, is out (#140): the
  // Pool page's line, as the window's chooser says it under the runtime's name.
  const poolNote = runtimes.find((r) => r.runtime.id === chosenRuntime)?.poolNote;
  const hostRecord = store.hosts.value.find((h) => h.id === host);
  const machine = host === "mac" ? "this Mac" : hostRecord?.name ?? host;
  const path = decodeURI(folderKey(folder).replace(/^file:\/\//, ""));
  // What the area under the input says when it has no menus, as the window's OptionsNote does.
  const setChosen = (id: string, value: JSONValue) => {
    form.value = { ...form.value, chosen: { ...form.value.chosen, [id]: value } };
    note({ runtimeID: chosenRuntime!, chosen: form.value.chosen });
  };
  const saying = !chosenRuntime ? <p class="quiet small">No runtime can start on this host.</p>
    : state === "loading" ? <p class="quiet small">Asking {runtimeName} what it offers…</p>
    : typeof state === "object" ? (
      <p class="failure small">{state.failed}{" "}
        <button class="link" onClick={() => (asking.value = asking.value + 1)}>Try again</button></p>
    )
    : !form.value.options.length ? <p class="quiet small">This runtime has no settings to choose.</p>
    : null;
  return (
    <section class="chat new-agent" aria-label="New session">
      <header class="column-head narrow-only">
        <BackToList />
      </header>
      {/* The same strip as over a chat: a prompt here goes to that host too (#83). */}
      {!down && <OfflineStrip store={store} host={host} />}
      <div class="scroll new-heading">
        <ProjectSwitch store={store} host={host} folder={folder} projectName={projectName} down={down} />
        <p class="quiet" title={path}>{path} · {machine}</p>
        {personas.value.length > 0 && (
          <div class="persona-choice">
            {usablePersonas.length > 0 && (isChatProject ? (
              <label class="pill select" title="Persona">
                <span aria-hidden="true">{usablePersonas.find((p) => p.id === persona.value)?.name ?? "No persona"} ▾</span>
                <select aria-label="Persona" disabled={down} value={persona.value ?? ""}
                  onChange={(e) => choosePersona((e.currentTarget as HTMLSelectElement).value)}>
                  <option value="">No persona</option>
                  {usablePersonas.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                </select>
              </label>
            ) : (
              <div class="segmented" role="radiogroup" aria-label="Persona">
                {[{ id: "", name: "None" }, ...usablePersonas].map((p) => (
                  <button key={p.id} role="radio" aria-checked={(persona.value ?? "") === p.id} disabled={down}
                    class={(persona.value ?? "") === p.id ? "on" : ""} onClick={() => choosePersona(p.id)}>{p.name}</button>
                ))}
              </div>
            ))}
            {description && <p class="quiet small">{description}</p>}
            {brokenPersonas.map((p) => <p key={p.id} class="quiet small">{p.id}.md: {p.problem}</p>)}
          </div>
        )}
        <KeptBubbles store={store} kept={keptStarts} />
      </div>
      <footer class="foot">
        {/* A change to the project's own files that no session can be asked about (#531). */}
        <GuardedChangeCards store={store} host={host} where={{ folder }} down={down || !store.hostIsOnline(host)} />
        <Prompt key={filled.value} store={store} draftKey={draftKey} placeholder="What should it do?"
          capabilities={capabilities} disabled={down || !chosenRuntime || (!store.hostIsOnline(host) && !store.startsWhenUsed(host))} send={start}
          recipient={store.recipient(host)} starting commands={form.value.commands}
          where={(
            <>
              {isRepository.value && (
                <label class="pill select" title="Where it works">
                  <span aria-hidden="true">{whereTitle(where.value, worktrees.value)} ▾</span>
                  <select aria-label="Works in" disabled={down} value={whereValue(where.value)}
                    onChange={(e) => {
                      const v = (e.currentTarget as HTMLSelectElement).value;
                      where.value = v === "project" ? { kind: "project" } : v === "new" ? { kind: "new" }
                        : v.startsWith("named:") ? { kind: "named", name: v.slice(6) }
                        : v.startsWith("branch:") ? { kind: "branch", name: v.slice(7) } : { kind: "existing", root: v.slice(9) };
                    }}>
                    <option value="project">Project folder</option>
                    {/* Shown when it can't be made, with why, as the window's (#257). */}
                    <option value="new" disabled={!canMakeNew.value}>
                      New worktree — {canMakeNew.value ? "A new branch from the last commit here" : whyNot.value ?? "Can't be made here"}</option>
                    {/* The one a view named (#834), offered while it is the place. */}
                    {where.value.kind === "named" && (
                      <option value={whereValue(where.value)}>New worktree — {where.value.name}</option>
                    )}
                    {/* A pull request's branch a view named (#837), when the list has not got it. */}
                    {where.value.kind === "branch" && !branches.value.some((b) => where.value.kind === "branch" && b.name === where.value.name) && (
                      <option value={whereValue(where.value)}>New worktree on {where.value.name}</option>
                    )}
                    {worktrees.value.length > 0 && (
                      <optgroup label="Worktrees">
                        {worktrees.value.map((w) => (
                          <option key={w.root} value={`existing:${w.root}`} disabled={!w.exists}>{w.name} — {worktreeDescription(w, store.worktreeSize(host, w))}</option>
                        ))}
                      </optgroup>
                    )}
                    {branches.value.length > 0 && (
                      <optgroup label="New worktree on a branch">
                        {branches.value.map((b) => (
                          <option key={b.name} value={`branch:${b.name}`}>{b.name}{b.remote ? ` — From ${b.remote}` : ""}</option>
                        ))}
                      </optgroup>
                    )}
                  </select>
                </label>
              )}
              <Reach folders={folders.value} change={(f) => { folders.value = f; note({ folders: f }); }} disabled={down} />
              <LabelField store={store} host={host} folder={folder} disabled={down} listID={`labels-new-${folderKey(folder)}`}
                labels={labels.value.map((value) => ({ value, owner: "person" }))}
                add={(values) => (labels.value = [...labels.value, ...values])}
                remove={(value) => (labels.value = labels.value.filter((l) => l.toLowerCase() !== value.toLowerCase()))} />
            </>
          )}
          runtime={(
            <label class="pill select" title="Runtime">
              <span aria-hidden="true">{chosenRuntime ? runtimeName : "Runtime"} ▾</span>
              <select aria-label="Runtime" value={chosenRuntime ?? ""} disabled={!runtimes.length || down}
                onChange={(e) => {
                  const id = (e.currentTarget as HTMLSelectElement).value;
                  runtimeID.value = id;
                  sandbox.value = undefined;
                  refusal.value = null;
                  note({ runtimeID: id, chosen: {} });
                }}>
                {!runtimes.length && <option value="">No runtime can start on this host</option>}
                {/* In runs only when one is out, as the window's chooser (065). */}
                {runs.out.length ? <optgroup label="Available">{runs.available.map(runtimeOption)}</optgroup> : runs.available.map(runtimeOption)}
                {runs.out.length > 0 && <optgroup label="Out">{runs.out.map(runtimeOption)}</optgroup>}
                {runs.cannot.length > 0 && <optgroup label="Can't start">{runs.cannot.map(runtimeOption)}</optgroup>}
              </select>
            </label>
          )}>
          {refusal.value && (
            <div class="sandbox-refusal" role="status">
              <div>
                <p class="strong small">{sandboxCardTitle(runtimeName)}</p>
                <p class="quiet small" title={refusal.value.detail}>{refusal.value.detail.split("\n")[0]}</p>
              </div>
              {refusal.value.offOffered && lastSent.current && (
                <button onClick={() => {
                  const sent = lastSent.current!;
                  sandbox.value = "off";
                  void start(sent.text, sent.attachments, "off").then((went) => {
                    if (went) store.drafts.delete(draftKey);
                  });
                }}>{startWithout}</button>
              )}
            </div>
          )}
          {saying}
          {(!saying || form.value.state === "ready") && (
            <PromptMenus options={form.value.options} value={(o) => form.value.chosen[o.id]}
              onChange={(o, v) => setChosen(o.id, v)} disabled={down} runtime={chosenRuntime ? runtimeName : undefined}
              besideMode={chosenRuntime && (
                <SandboxPill runtimeID={chosenRuntime} name={runtimeName} override={sandbox.value} runtimeDefault={runtimeDefault}
                  codexMode={typeof codexMode === "string" ? codexMode : undefined} disabled={down}
                  choose={(choice) => {
                    sandbox.value = choice;
                    // Codex's sandbox is its mode (FR-005a): the draft's mode follows.
                    if (chosenRuntime === "codex" && modeID) {
                      if (choice === "off") setChosen(modeID, "agent-full-access");
                      else if (choice === "on" && codexMode === "agent-full-access") setChosen(modeID, "read-only");
                    }
                  }} />
              )} />
          )}
          {poolNote && <p class="quiet small">{runtimeName}: {poolNote}</p>}
        </Prompt>
      </footer>
    </section>
  );
}

/** What the Works in chip says: the window's words for the place. */
function whereTitle(where: Where, worktrees: WorktreeSummary[]): string {
  if (where.kind === "project") return "Project folder";
  if (where.kind === "new") return "New worktree";
  if (where.kind === "branch" || where.kind === "named") return where.name;
  return worktrees.find((w) => w.root === where.root)?.name ?? "Worktree";
}

function whereValue(where: Where): string {
  if (where.kind === "existing") return `existing:${where.root}`;
  if (where.kind === "branch") return `branch:${where.name}`;
  if (where.kind === "named") return `named:${where.name}`;
  return where.kind;
}

/** Its branch, who is in it and how much it holds (#790), as the window's worktreeDescription. */
function worktreeDescription(worktree: WorktreeSummary, size?: WorktreeSize): string {
  if (!worktree.exists) return "Missing";
  const branch = worktree.branch ?? "detached";
  const n = worktree.agents.length;
  const held = size ? ` · ${sizeWords(size)}` : "";
  return (n === 0 ? branch : `${branch} · ${n} agent${n === 1 ? "" : "s"} working`) + held;
}

/**
 * The command sandbox, beside the mode it is so often mistaken for (064; SandboxCapsule): a menu
 * where the runtime has a route, else its state, with why as the tooltip.
 */
function SandboxPill({ runtimeID, name, override, runtimeDefault, codexMode, disabled, choose }: {
  runtimeID: string; name: string; override: SandboxChoice | undefined; runtimeDefault: SandboxChoice;
  codexMode: string | undefined; disabled: boolean; choose: (choice: SandboxChoice | undefined) => void;
}) {
  const choices = sandboxChoices(runtimeID);
  const words = sandboxStateWords(sandboxState(runtimeID, override ?? runtimeDefault, codexMode));
  if (!choices.length) return <span class="pill quiet" title={sandboxWhy(runtimeID) ?? words}>{words}</span>;
  return (
    <label class="pill select" title="Command sandbox">
      <span aria-hidden="true">{words} ▾</span>
      <select aria-label="Command sandbox" disabled={disabled} value={override ?? ""}
        onChange={(e) => {
          const v = (e.currentTarget as HTMLSelectElement).value;
          choose(v === "" ? undefined : v as SandboxChoice);
        }}>
        <option value="">{sandboxOverrideWords(undefined, runtimeDefault, runtimeID)}</option>
        {choices.map((c) => (
          <option key={c} value={c} title={sandboxExplanation(c, runtimeID, name)}>{sandboxChoiceWords(c, runtimeID)}</option>
        ))}
      </select>
    </label>
  );
}

/** A view's agents/start-agent (#834): this form, in the view's project, filled in. Why it was
 *  not, or null. Nothing starts: the form waits for the person's Start. */
export function offerStart(store: Store, host: string, folder: string, start: Start): string | null {
  const project = (store.projects.value[host] ?? []).find((p) => folderKey(p.project.folder) === folderKey(folder));
  if (!project) return `${decodeURIComponent(folderKey(folder).split("/").pop() ?? folder)} is not a project here.`;
  store.offeredStart.value = { host, folder: project.project.folder, start };
  go({ host, project: project.project.folder, compose: true });
  return null;
}

/**
 * The project's name, a menu of every project to start in another instead (#495, #499): the
 * sidebar has one New Session, at its top, in the project last started in.
 */
function ProjectSwitch({ store, host, folder, projectName, down }: {
  store: Store; host: string; folder: string; projectName: string; down: boolean;
}) {
  const projects = orderedProjects(store.hosts.value, store.projects.value);
  const at = projects.findIndex((p) => p.host.id === host && folderKey(p.project.project.folder) === folderKey(folder));
  if (projects.length < 2 || at < 0) return <h1>{projectName}</h1>;
  return (
    <h1 class="project-switch" title="Start it in another project">
      <span aria-hidden="true">{projectLabel(projects[at]!.host, projects[at]!.project)} <span class="caret">▾</span></span>
      <select aria-label="Project" disabled={down} value={String(at)}
        onChange={(e) => {
          const picked = projects[Number((e.currentTarget as HTMLSelectElement).value)];
          if (picked) go({ host: picked.host.id, project: picked.project.project.folder, compose: true });
        }}>
        {projects.map(({ host: h, project: p }, i) => <option key={`${h.id}|${p.project.folder}`} value={String(i)}>{projectLabel(h, p)}</option>)}
      </select>
    </h1>
  );
}
