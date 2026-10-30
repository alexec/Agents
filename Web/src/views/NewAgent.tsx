// A new session (071 FR-026): the folder's empty pane is the new chat, as in the window (066):
// the folder's name and folder in the middle, and the prompt bar at the foot (#108). Over the
// input, where it works (the folder, a new worktree, or one already there), what else it
// may reach and its labels on the left, and the runtime on the right; under it, the runtime's own
// menus. Started on the folder's host with `agents/start`. A runtime is started behind the bar
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
import type { AccountProfile, Attachment, BranchSummary, ClientPermissionSettings, ConfigOption, JSONValue, Persona, PolicySetBy, RuntimeStatus, SandboxChoice, SlashCommand, StartRequest, UUID, WorktreeSize,
  WorktreeSummary } from "../protocol/generated";
import type { SandboxWillNotStart, Store } from "../model/store";
import { drawable, modeOption, modeStartsOn } from "../model/options";
import { keep, rememberOptions, rememberedOptions } from "../model/startMemory";
import { folderKey } from "../model/groups";
import { fromWireDate } from "../protocol/dates";
import { accountChoices, accountRows, choiceNote, defaultAccountName, formRuntime, newSessionRuntime, ownRow, ownSignInID, runtimeRuns, unavailableReason } from "../model/runtimes";
import { formFor, keepForm, keptForm } from "../model/startForm";
import { personaChoices, withPersonaLabels } from "../model/personas";
import { sandboxCardTitle, sandboxChoiceWords, sandboxChoices, sandboxExplanation, sandboxOverrideWords, sandboxState,
  sandboxStateWords, sandboxWhy, startWithout, fixedSandbox, sandboxRefusedBy } from "../model/sandbox";
import { autoID, autoWords, cellOf, fieldWords, followsSettings, levelMeaning, levelWords, matchLevel, noneIncluded, picksWords, sandboxValues } from "../model/levels";
import type { AutoPreview, ClientPermissionMode, Levels } from "../protocol/generated";
import { accepted } from "../model/labels";
import type { Start } from "./chat/appViewBridge";
import { go } from "../route";
import { sizeWords } from "../model/worktrees";
import { LabelField } from "./Labels";
import { Huddle } from "./Huddle";
import { Reach } from "./Reach";
import { Prompt } from "./Prompt";
import { OfflineStrip } from "./OfflineStrip";
import { DiskStrip } from "./DiskStrip";
import { LevelSelect, PromptMenus, type LevelProps } from "./PromptMenus";
import { BackToList } from "./BackToList";
import { orderedFolders, folderLabel } from "./Sidebar";
import { GuardedChangeCards } from "./GuardedChange";
import { KeptBubbles } from "./Kept";
import { composerReason, line, setBy as setByWords } from "../model/orgPolicy";
import { optionLabel } from "./OrgPolicyLine";

type Where = { kind: "folder" } | { kind: "new" } | { kind: "existing"; root: string } | { kind: "branch"; name: string }
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

export function NewAgent({ store, host, folder, folderName, down }: {
  store: Store; host: string; folder: string; folderName: string; down: boolean;
}) {
  const listed = store.runtimes.value[host] ?? [];
  const runs = runtimeRuns(listed);
  const runtimes = [...runs.available, ...runs.out];
  // The form as it was left, its runtime only while that can still start (DraftKeeper).
  const kept = useSignal(keptForm(storage));
  // Auto first, wherever a runtime can start (#2658).
  const startable = runtimes.length ? [autoID, ...runtimes.map((r) => r.runtime.id)] : [];
  const left = formFor(kept.value, startable);
  const runtimeID = useSignal<string | undefined>(undefined);
  // The one rule (#264), frozen when the form opens (#291): a later listing, or another agent's
  // activity, does not move it and so does not discard the draft runtime and start another.
  const openedRuntime = useRef<{ host: string; folder: string; runtimeID?: string }>({ host, folder });
  if (openedRuntime.current.host !== host || openedRuntime.current.folder !== folder) openedRuntime.current = { host, folder };
  if (openedRuntime.current.runtimeID === undefined) {
    const lastUsed = chosenRuntimeOf((store.agents.value[host] ?? [])[0]);
    const opening = newSessionRuntime(lastUsed, left.runtimeID, startable);
    if (opening !== undefined) openedRuntime.current = { host, folder, runtimeID: opening };
  }
  // A runtime picked here counts only while this host offers it: the bar can move to another host.
  const picked = runtimeID.value !== undefined && startable.includes(runtimeID.value) ? runtimeID.value : undefined;
  const lastUsedRuntime = chosenRuntimeOf((store.agents.value[host] ?? [])[0]);
  const chosenRuntime = formRuntime(openedRuntime.current.runtimeID, picked, startable, lastUsedRuntime, left.runtimeID);
  /** The added account the session uses (#840); undefined for the runtime's own sign-in. */
  const accountID = useSignal<string | undefined>(undefined);
  const where = useSignal<Where>({ kind: "folder" });
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
  /** The values in the shared words (#2658), kept when the runtime changes. */
  const levels = useSignal<Levels>({ model: "balanced", permission: "ask" });
  /** This session's own answer to permission requests; none follows Settings (FR-019). */
  const clientPermission = useSignal<ClientPermissionMode | undefined>(undefined);
  /** What Auto would pick now, and why the last start on Auto did not happen. */
  const autoPreview = useSignal<AutoPreview | null>(null);
  const autoRefusal = useSignal<string | null>(null);
  const refusal = useSignal<SandboxWillNotStart | null>(null);
  /** What was last sent, for Start without sandbox to send again. */
  const lastSent = useRef<{ text: string; attachments: Attachment[] } | null>(null);
  /** The kept starts this page has shown: the one that reaches its host opens here (#691 US3). */
  const keptShown = useRef(new Set<string>());
  /** Asked again by Try again. */
  const asking = useSignal(0);
  /** The folder's personas (#760), the one picked by id, and one picked before its runtime's menus came. */
  const personas = useSignal<Persona[]>([]);
  const persona = useSignal<string | undefined>(undefined);
  const pendingPersona = useRef<Persona | undefined>(undefined);
  /** The folder the personas came for, when they came: asked again once the host answers if not (#1096). */
  const personasFor = useRef("");
  /** A new worktree a view named (#834), or a branch it named (#837), made the place once the folder is
   *  known to be a repository. */
  const offeredWorktree = useRef<Where | undefined>(undefined);
  /** The folder whose worktrees are listed, so an offer knows whether it can be placed now. */
  const listedFor = useRef("");
  /** Counts the offers taken: the prompt field opens afresh on each, with the view's words. */
  const filled = useSignal(0);
  /** Whether the prompt has focus and how much it holds, for the Blobs over the page (#987). */
  const promptFocused = useSignal(false);
  const typed = useSignal(0);
  const placeOffered = () => {
    const offered = offeredWorktree.current;
    offeredWorktree.current = undefined;
    if (offered && isRepository.peek()) where.value = offered;
  };

  useEffect(() => {
    // What each runtime takes changes once it has run: asked again as the form opens.
    void store.loadRuntimes(host);
    where.value = { kind: "folder" };
    folders.value = keptForm(storage).folders;
    labels.value = [];
    offeredWorktree.current = undefined;
    listedFor.current = "";
    refusal.value = null;
    persona.value = undefined;
    pendingPersona.current = undefined;
    personas.value = [];
    personasFor.current = "";
    askPersonas();
    void store.worktrees(host, folder).then((list) => {
      worktrees.value = (list?.worktrees ?? []).filter((w) => !w.isFolder);
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

  // The folder's personas. One the host did not answer stays to be asked again, rather than
  // leaving the page with no Persona row until it is opened again (#1096).
  function askPersonas() {
    const key = `${host}|${folderKey(folder)}`;
    void store.personas(host, folder).then((list) => {
      if (list === null || key !== `${host}|${folderKey(folder)}`) return;
      personas.value = list;
      personasFor.current = key;
    });
  }

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

  // A draft runtime for the folder it will work in, asked again when either changes. Drawn at
  // once from what the runtime offered last time (#1171), and put right by the draft's answer;
  // a Send before that answer starts with the choices on the form, without the draft.
  const cwd = where.value.kind === "existing" ? where.value.root : folder;
  useEffect(() => {
    if (!chosenRuntime) return;
    // Auto has no runtime yet, so no options of its own (#2658).
    if (chosenRuntime === autoID) {
      form.value = { options: [], chosen: {}, state: "ready" };
      return;
    }
    let current = true;
    // The first draw opens on the choices left; a later one keeps what was chosen since.
    const draw = (offered: ConfigOption[], opening: boolean) => {
      const options = drawable(undefined, offered);
      let chosen: Record<string, JSONValue>;
      if (opening) {
        const mode = modeOption(options);
        const value = mode ? modeStartsOn(store.rememberedModes.value[host]?.[chosenRuntime], mode) : undefined;
        // The choices left on this runtime, where they are still choices; the mode remembered otherwise.
        const left = kept.peek().runtimeID === chosenRuntime ? kept.peek().chosen : {};
        chosen = keep(options, mode && value !== undefined && left[mode.id] === undefined ? { ...left, [mode.id]: value } : left);
      } else {
        chosen = keep(options, form.peek().chosen);
      }
      // The values in the shared words, over the mode remembered (#2658).
      if (opening) chosen = { ...chosen, ...levelOptions(options) };
      // Over the mode remembered, because the persona was picked after it (#760).
      const waiting = pendingPersona.current;
      if (waiting && options.length) {
        chosen = { ...chosen, ...personaChoices(waiting, options) };
        pendingPersona.current = undefined;
      }
      return { options, chosen };
    };
    const remembered = rememberedOptions(host, chosenRuntime);
    form.value = remembered ? { ...draw(remembered, true), state: "ready" } : { options: [], chosen: {}, state: "loading" };
    void store.draft(host, chosenRuntime, cwd).then((answer) => {
      if (!current) {
        if ("draftID" in answer) store.discardDraft(host, answer.draftID);
        return;
      }
      if ("failure" in answer) {
        form.value = { options: [], chosen: {}, state: { failed: answer.failure } };
        return;
      }
      rememberOptions(host, chosenRuntime, answer.options);
      form.value = { draftID: answer.draftID, ...draw(answer.options, !remembered), commands: answer.commands, state: "ready" };
    });
    return () => {
      current = false;
      const draft = form.peek().draftID;
      if (draft) store.discardDraft(host, draft);
    };
  }, [host, chosenRuntime, cwd, asking.value]);

  // Back in touch (#1047): choices that failed, or never came, are asked again, as Try again
  // would, rather than kept until the form is closed and opened.
  const reachable = !down && store.hostIsOnline(host);
  const wasReachable = useRef(reachable);
  useEffect(() => {
    const cameBack = reachable && !wasReachable.current;
    wasReachable.current = reachable;
    if (cameBack && form.peek().state !== "ready") asking.value = asking.peek() + 1;
    if (cameBack && personasFor.current !== `${host}|${folderKey(folder)}`) askPersonas();
  }, [reachable]);

  // The correction to a form answered from memory.
  const correction = store.draftOptions.value;
  useEffect(() => {
    if (!correction || correction.draftID !== form.peek().draftID) return;
    if (correction.failure) {
      form.value = { options: [], chosen: {}, state: { failed: correction.failure } };
      return;
    }
    if (chosenRuntime) rememberOptions(host, chosenRuntime, correction.options);
    const options = drawable(undefined, correction.options);
    form.value = { ...form.peek(), options, commands: correction.commands, chosen: keep(options, form.peek().chosen), state: "ready" };
  }, [correction]);

  // Pick a kind of session (#760): what it names is set, what it leaves out stays as the form has it.
  const choosePersona = (id: string) => {
    const picked = personas.value.find((p) => p.id === id && p.problem === undefined);
    const last = personas.value.find((p) => p.id === persona.value);
    labels.value = withPersonaLabels(labels.value, last, picked);
    persona.value = picked?.id;
    pendingPersona.current = undefined;
    if (!picked) return;
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
  const description = usablePersonas.find((p) => p.id === persona.value)?.description;

  // What Auto would pick now, for "Picks Claude now" and each value's line (#2658).
  const isAuto = chosenRuntime === autoID;
  useEffect(() => {
    if (!chosenRuntime) return;
    let current = true;
    void store.autoPreview(host, { cwd: cwd as never, levels: levels.value, ...(sandbox.value ? { sandbox: sandbox.value } : {}) })
      .then((p) => { if (current) autoPreview.value = p; });
    return () => { current = false; };
  }, [host, cwd, isAuto, levels.value, sandbox.value, store.autoSettings.value]);
  const mappings = store.autoMappings.value[store.macHostID.value];
  /** The options a value sets on the chosen runtime, where it offers them. */
  function levelOptions(options: ConfigOption[], only?: "model" | "permission"): Record<string, JSONValue> {
    if (!chosenRuntime || chosenRuntime === autoID) return {};
    const out: Record<string, JSONValue> = {};
    for (const field of (only ? [only] : ["model", "permission"]) as ("model" | "permission")[]) {
      const level = levels.peek()[field];
      const cell = level ? cellOf(mappings, chosenRuntime, field, level) : undefined;
      if (!cell || cell.mark === "notPossible" || cell.mark === "dropped") continue;
      for (const [id, v] of Object.entries(cell.native?.options ?? {})) if (options.some((o) => o.id === id)) out[id] = v;
    }
    return out;
  }
  const levelProps: LevelProps = {
    // On a named runtime too, so the menus show "⋯ <runtime>'s own" as the chat's do (#2889).
    runtimeName: isAuto ? (autoPreview.value?.runtimeID ? runtimeNameOf(autoPreview.value.runtimeID) : undefined)
      : chosenRuntime ? runtimeNameOf(chosenRuntime) : undefined,
    chosen: (field) => isAuto ? levels.value[field]
      : matchLevel(mappings, chosenRuntime ?? "", field, (id) => form.value.chosen[id] ?? form.value.options.find((o) => o.id === id)?.currentValue),
    cell: (field, level) => cellOf(mappings, (isAuto ? autoPreview.value?.runtimeID : chosenRuntime) ?? "", field, level),
    choose: (field, level) => {
      levels.value = { ...levels.value, [field]: level };
      autoRefusal.value = null;
      if (!isAuto) {
        const set = levelOptions(form.value.options, field);
        form.value = { ...form.value, chosen: { ...form.value.chosen, ...set } };
        note({ runtimeID: chosenRuntime!, chosen: form.value.chosen });
      }
    },
  };
  function runtimeNameOf(id: string): string {
    return listed.find((r) => r.runtime.id === id)?.runtime.name ?? id;
  }
  // Under Auto in the chooser: what it picks now, or that none is included.
  const excluded = store.autoSettings.value[store.macHostID.value]?.excluded ?? [];
  const autoNote = runtimes.length && runtimes.every((r) => excluded.includes(r.runtime.id)) ? noneIncluded
    : picksWords(autoPreview.value?.runtimeID ? runtimeNameOf(autoPreview.value.runtimeID) : undefined);

  const capabilities = chosenRuntime ? store.account(host, chosenRuntime)?.promptCapabilities : undefined;
  // The runtime's accounts beyond its own sign-in (#840), the organisation's included (#999): the
  // picker shows only when there is one. Undefined is the runtime's account for new sessions.
  // This Mac's only, as on the other two: no client signs in a server's account (#2257).
  const choices = accountChoices(chosenRuntime ?? "", chosenRuntime && store.isMac(host) ? store.addedAccounts(host, chosenRuntime) : [],
    store.policyStates.value[host]?.policy);
  // Under each choice, why it cannot be used or that its allowance is out (#2265).
  const allowanceSet = store.runtimeAllowances.value[host];
  const accountNote = (account: AccountProfile | undefined): string => {
    const rows = allowanceSet?.rows ?? [];
    const row = account ? accountRows(rows, chosenRuntime ?? "").find((r) => r.accountID === account.id) : ownRow(rows, chosenRuntime ?? "");
    const words = choiceNote(account, row, allowanceSet ? fromWireDate(allowanceSet.at) : new Date());
    return words ? ` · ${words}` : "";
  };
  const chosenAccount = choices.account(accountID.value);
  const sentAccount = choices.sent(accountID.value);

  const start = async (text: string, attachments: Attachment[], override = sandbox.value) => {
    if (!chosenRuntime) {
      store.say("Choose a runtime to start.");
      return false;
    }
    lastSent.current = { text, attachments };
    refusal.value = null;
    autoRefusal.value = null;
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
      ...(sentAccount && !isAuto ? { accountID: sentAccount } : {}),
      levels: { ...levels.value, ...(clientPermission.value && !isAuto ? { permissionRequests: clientPermission.value } : {}) },
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
    if (typeof id === "object" && "autoRefusal" in id) {
      // No runtime Auto may use can take it: each runtime and why, over the prompt (FR-011).
      autoRefusal.value = id.autoRefusal;
      return false;
    }
    if (typeof id === "object") {
      refusal.value = id;
      return false;
    }
    store.finishStartRequest(host, folder);
    note({ runtimeID: chosenRuntime, chosen: form.value.chosen, folders: folders.value });
    sandbox.value = undefined;
    clientPermission.value = undefined;
    // The runtime behind the form is the agent's now.
    const { draftID: _taken, ...rest } = form.value;
    form.value = rest;
    go({ host, folder: folder, session: id });
    return true;
  };

  // Starts kept for this folder's stopped workspace; the one that reaches it opens (#691 US3).
  const keptStarts = store.keptStarts(host, folder);
  const delivered = store.keptDelivered.value;
  useEffect(() => {
    if (delivered?.agentID && delivered.host === host && keptShown.current.has(delivered.id)) {
      go({ host, folder: folder, session: delivered.agentID });
    }
  }, [delivered]);
  useEffect(() => { for (const k of keptStarts) keptShown.current.add(k.id); }, [keptStarts]);

  const state = form.value.state;
  // Why nothing can start on this host now, in its organisation's words (#998).
  const refusedHere = composerReason(store.policyStates.value[host]);
  const runtimeName = chosenRuntime === autoID ? autoWords : listed.find((r) => r.runtime.id === chosenRuntime)?.runtime.name ?? "the runtime";
  /** Under a runtime's name: its pool note, else whether it is signed in (the window's signInNote). */
  const runtimeNote = (r: RuntimeStatus) => {
    if (r.poolNote) return r.poolNote;
    const account = store.account(host, r.runtime.id);
    return account?.state === "needsSignIn" ? "Needs signing in" : account?.signedInAs?.label;
  };
  const runtimeOption = (r: RuntimeStatus) => {
    const said = unavailableReason(r) ?? runtimeNote(r);
    return <option key={r.runtime.id} value={r.runtime.id} disabled={!("available" in r.availability) || !!r.setBy} title={said ?? ""}>
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
  const machine = store.isMac(host) ? "this Mac" : hostRecord?.name ?? host;
  const path = decodeURI(folderKey(folder).replace(/^file:\/\//, ""));
  // What the area under the input says when it has no menus, as the window's OptionsNote does.
  const setChosen = (id: string, value: JSONValue) => {
    form.value = { ...form.value, chosen: { ...form.value.chosen, [id]: value } };
    note({ runtimeID: chosenRuntime!, chosen: form.value.chosen });
  };
  const saying = !chosenRuntime ? <p class="quiet small">No runtime can start on this machine.</p>
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
      {!down && <DiskStrip store={store} host={host} />}
      <div class="scroll new-heading">
        <Huddle focused={promptFocused.value} typed={typed.value} />
        <FolderSwitch store={store} host={host} folder={folder} folderName={folderName} down={down} />
        {personas.value.length > 0 && (
          <div class="persona-choice">
            {usablePersonas.length > 0 && (
              <PersonaSwitch personas={usablePersonas} picked={persona.value} down={down} choose={choosePersona} />
            )}
            {description && <p class="quiet small">{description}</p>}
            {brokenPersonas.map((p) => <p key={p.id} class="quiet small">{p.id}.md: {p.problem}</p>)}
          </div>
        )}
        <p class="quiet" title={path}>{path} · {machine}</p>
        <KeptBubbles store={store} kept={keptStarts} />
      </div>
      <footer class="foot"
        onFocusIn={(e) => { if (isPrompt(e.target)) { promptFocused.value = true; typed.value = e.target.value.length; } }}
        onFocusOut={(e) => { if (isPrompt(e.target)) promptFocused.value = false; }}
        onInput={(e) => { if (isPrompt(e.target)) typed.value = e.target.value.length; }}>
        {/* A change to the folder's own files that no session can be asked about (#531). */}
        <GuardedChangeCards store={store} host={host} where={{ folder }} down={down || !store.hostIsOnline(host)} />
        <Prompt key={filled.value} store={store} draftKey={draftKey} placeholder={refusedHere ?? "What should it do?"}
          capabilities={capabilities} disabled={down || !chosenRuntime || refusedHere !== null
            || (!store.hostIsOnline(host) && !store.startsWhenUsed(host))} send={start}
          recipient={store.recipient(host)} starting commands={form.value.commands}
          where={(
            <>
              {isRepository.value && (
                <label class="pill select" title="Where it works">
                  <span aria-hidden="true">{whereTitle(where.value, worktrees.value)} ▾</span>
                  <select aria-label="Works in" disabled={down} value={whereValue(where.value)}
                    onChange={(e) => {
                      const v = (e.currentTarget as HTMLSelectElement).value;
                      where.value = v === "folder" ? { kind: "folder" } : v === "new" ? { kind: "new" }
                        : v.startsWith("named:") ? { kind: "named", name: v.slice(6) }
                        : v.startsWith("branch:") ? { kind: "branch", name: v.slice(7) } : { kind: "existing", root: v.slice(9) };
                    }}>
                    <option value="folder">Folder</option>
                    {/* Shown when it can't be made, with why, as the window's (#257). */}
                    <option value="new" disabled={!canMakeNew.value}>
                      New worktree — {canMakeNew.value ? "A new branch from the last commit here" : whyNot.value ?? "Can't be made here"}</option>
                    {/* The one a view named (#834), offered while it is the place. */}
                    {where.value.kind === "named" && (
                      <option value={whereValue(where.value)}>New worktree — {oneLine(where.value.name)}</option>
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
          runtime={(<>
            <label class="pill select" title="Runtime">
              <span aria-hidden="true">{chosenRuntime ? runtimeName : "Runtime"} ▾</span>
              <select aria-label="Runtime" value={chosenRuntime ?? ""} disabled={!runtimes.length || down}
                onChange={(e) => {
                  const id = (e.currentTarget as HTMLSelectElement).value;
                  runtimeID.value = id;
                  accountID.value = undefined;
                  sandbox.value = undefined;
                  clientPermission.value = undefined;
                  refusal.value = null;
                  autoRefusal.value = null;
                  note({ runtimeID: id, chosen: {} });
                }}>
                {!runtimes.length && <option value="">No runtime can start on this machine</option>}
                {/* Auto first (#2658): the host picks the runtime when the session starts. */}
                {runtimes.length > 0 && <option value={autoID}>{autoWords} — {autoNote}</option>}
                {/* In runs only when one is out, as the window's chooser (065). */}
                {runs.out.length ? <optgroup label="Available">{runs.available.map(runtimeOption)}</optgroup> : runs.available.map(runtimeOption)}
                {runs.out.length > 0 && <optgroup label="Out">{runs.out.map(runtimeOption)}</optgroup>}
                {runs.cannot.length > 0 && <optgroup label="Can't start">{runs.cannot.map(runtimeOption)}</optgroup>}
              </select>
            </label>
            {/* Which of the runtime's accounts (#840, #999): only when it has more than one. One the
                organisation's policy refuses is shown, dimmed, and cannot be chosen. */}
            {choices.shows && <label class="pill select" title="Account">
              <span aria-hidden="true">{choices.name(accountID.value)} ▾</span>
              <select aria-label="Account" value={chosenAccount?.id ?? ownSignInID} disabled={down}
                onChange={(e) => {
                  const id = (e.currentTarget as HTMLSelectElement).value;
                  accountID.value = id === ownSignInID ? choices.ownChoice : id;
                }}>
                <option value={ownSignInID} disabled={!!choices.ownSetBy}>{defaultAccountName}{choices.ownSetBy ? ` (${setByWords})` : accountNote(undefined)}</option>
                {choices.accounts.map((a) => <option key={a.id} value={a.id} disabled={!!a.setBy}>{a.name}{a.setBy ? ` (${setByWords})` : accountNote(a)}</option>)}
              </select>
            </label>}
          </>)}>
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
          {autoRefusal.value && (
            <div class="sandbox-refusal" role="status">
              <p class="quiet small">{autoRefusal.value}</p>
              <button onClick={() => go({ settings: true })}>Auto settings</button>
            </div>
          )}
          {isAuto ? (
            // On Auto: Permission mode, Sandbox and Model, each said as it is on the runtime Auto
            // picks now; no Permission requests, which follow the mode (FR-010).
            <div class="menus" role="group" aria-label="Settings for this session">
              <LevelSelect field="permission" levels={levelProps} own={[]} disabled={down} />
              <label class="pill select" title={fieldWords.sandbox}>
                <span aria-hidden="true">{levelWords("sandbox", sandbox.value ?? "runtime")} ▾</span>
                <select aria-label="Sandbox" disabled={down} value={sandbox.value ?? "runtime"}
                  onChange={(e) => {
                    const v = (e.currentTarget as HTMLSelectElement).value as SandboxChoice;
                    sandbox.value = v === "runtime" ? undefined : v;
                  }}>
                  {sandboxValues.map((v) => {
                    const cell = levelProps.cell("sandbox", v);
                    // While the organisation requires the sandbox, each choice but On is shown, dimmed, not chosen (#998, #2891).
                    const refusedBy = sandboxRefusedBy(v, store.sandboxSetBy.value[host]);
                    return <option key={v} value={v} disabled={!!refusedBy} title={refusedBy ? line(refusedBy) : undefined}>
                      {optionLabel(`${levelWords("sandbox", v)} — ${cell ? `${cell.words} on ${levelProps.runtimeName}` : levelMeaning("sandbox", v)}`, refusedBy)}</option>;
                  })}
                </select>
              </label>
              <span class="spacer" />
              <span class="menus-right"><LevelSelect field="model" levels={levelProps} own={[]} disabled={down} /></span>
            </div>
          ) : saying}
          {!isAuto && (!saying || form.value.state === "ready") && (
            <PromptMenus options={form.value.options} value={(o) => form.value.chosen[o.id]} levels={levelProps}
              onChange={(o, v) => setChosen(o.id, v)} disabled={down} runtime={chosenRuntime ? runtimeName : undefined}
              runtimeID={chosenRuntime ?? undefined}
              clientPermission={chosenRuntime ? {
                own: clientPermission.value,
                settings: store.clientPermissions.value[store.macHostID.value]?.[chosenRuntime as Exclude<keyof ClientPermissionSettings, "setBy">] ?? "default",
                set: (mode) => (clientPermission.value = mode),
              } : undefined}
              besideMode={chosenRuntime && (
                <SandboxPill runtimeID={chosenRuntime} name={runtimeName} override={sandbox.value} runtimeDefault={runtimeDefault}
                  codexMode={typeof codexMode === "string" ? codexMode : undefined} disabled={down}
                  setBy={store.sandboxSetBy.value[host]}
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

/** The runtime the person chose for an agent: Auto for one Auto picked a runtime for (#2658), so
 *  the next session opens on Auto too. */
function chosenRuntimeOf(agent: { runtimeID: string; auto?: unknown } | undefined): string | undefined {
  return agent ? (agent.auto ? autoID : agent.runtimeID) : undefined;
}

/** The prompt's own field, not another control in the bar. */
function isPrompt(target: EventTarget | null): target is HTMLTextAreaElement {
  return target instanceof HTMLTextAreaElement && target.getAttribute("aria-label") === "Prompt";
}

/** What the Works in chip says: the window's words for the place. */
function whereTitle(where: Where, worktrees: WorktreeSummary[]): string {
  if (where.kind === "folder") return "Folder";
  // A named one's name is long and is not what the daemon calls it (#2659): the menu shows it.
  if (where.kind === "new" || where.kind === "named") return "New worktree";
  if (where.kind === "branch") return where.name;
  return worktrees.find((w) => w.root === where.root)?.name ?? "Worktree";
}

/** A name cut to one menu line with "…" (#2659). */
function oneLine(name: string, max = 48): string {
  return name.length > max ? `${name.slice(0, max - 1).trimEnd()}…` : name;
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
function SandboxPill({ runtimeID, name, override, runtimeDefault, codexMode, disabled, choose, setBy }: {
  runtimeID: string; name: string; override: SandboxChoice | undefined; runtimeDefault: SandboxChoice;
  codexMode: string | undefined; disabled: boolean; choose: (choice: SandboxChoice | undefined) => void;
  /** The organisation's mark while its policy requires the sandbox (#998): only On is in force. */
  setBy?: PolicySetBy | undefined;
}) {
  const choices = sandboxChoices(runtimeID);
  const state = sandboxStateWords(sandboxState(runtimeID, override ?? runtimeDefault, codexMode));
  // A runtime that cannot change its sandbox: its fixed value, and why (#2658).
  if (!choices.length) {
    return <span class="pill quiet" title={setBy ? line(setBy) : sandboxWhy(runtimeID) ?? state}>{sandboxChoiceWords(fixedSandbox(runtimeID), runtimeID)}</span>;
  }
  const refused = (choice: SandboxChoice) => sandboxRefusedBy(choice, setBy) !== undefined;
  const asked = override ?? runtimeDefault;
  return (
    <label class="pill select" title={`${fieldWords.sandbox}: ${state}`}>
      <span aria-hidden="true">{sandboxOverrideWords(override, runtimeDefault, runtimeID)} ▾</span>
      <select aria-label="Sandbox" disabled={disabled} value={asked}
        onChange={(e) => {
          const v = (e.currentTarget as HTMLSelectElement).value as SandboxChoice;
          // The value Settings gives, chosen again, follows Settings still.
          choose(override === undefined && v === runtimeDefault ? undefined : v);
        }}>
        {choices.map((c) => (
          <option key={c} value={c} disabled={refused(c)} title={refused(c) ? line(setBy!) : sandboxExplanation(c, runtimeID, name)}>
            {optionLabel(override === undefined && c === runtimeDefault ? `${sandboxChoiceWords(c, runtimeID)} (${followsSettings})` : sandboxChoiceWords(c, runtimeID),
              refused(c) ? setBy : undefined)}</option>
        ))}
      </select>
    </label>
  );
}

/** A view's agents/start-agent (#834): this form, in the view's folder, filled in. Why it was
 *  not, or null. Nothing starts: the form waits for the person's Start. */
export function offerStart(store: Store, host: string, folder: string, start: Start): string | null {
  const summary = (store.folders.value[host] ?? []).find((p) => folderKey(p.folder.folder) === folderKey(folder));
  if (!summary) return `${decodeURIComponent(folderKey(folder).split("/").pop() ?? folder)} is not a folder here.`;
  store.offeredStart.value = { host, folder: summary.folder.folder, start };
  go({ host, folder: summary.folder.folder, compose: true });
  return null;
}

/**
 * The folder's name, a menu of every folder to start in another instead (#495, #499): the
 * sidebar has one New Session, at its top, in the folder last started in.
 */
/** The kind of session to start (#760), the same control as the folder's name, a size smaller,
    on its own line under it (#913). */
function PersonaSwitch({ personas, picked, down, choose }: {
  personas: Persona[]; picked: string | undefined; down: boolean; choose: (id: string) => void;
}) {
  const name = personas.find((p) => p.id === picked)?.name;
  // The segments when they fit; where they do not, a menu drawn as the folder's (#2795). The
  // segments stay, hidden, so a wider page can bring them back.
  const box = useRef<HTMLDivElement>(null);
  const segments = useRef<HTMLDivElement>(null);
  const fits = useSignal(true);
  useEffect(() => {
    const b = box.current, s = segments.current;
    if (!b || !s) return;
    const measure = () => { fits.value = s.scrollWidth <= b.clientWidth; };
    measure();
    const resized = new ResizeObserver(measure);
    resized.observe(b);
    resized.observe(s);
    return () => resized.disconnect();
  }, [personas]);
  return (
    <div ref={box} class={`persona-switch${name ? "" : " none"}${fits.value ? "" : " menu"}`} title="Start a kind of session: a persona sets what it names">
      <div ref={segments} class="segmented persona-segments" role="group" aria-label="Persona" aria-hidden={!fits.value}>
        <button type="button" aria-pressed={picked === undefined} class={picked === undefined ? "on" : ""}
          disabled={down} tabIndex={fits.value ? undefined : -1} onClick={() => choose("")}>No persona</button>
        {personas.map((persona) => (
          <button key={persona.id} type="button" aria-pressed={picked === persona.id}
            class={picked === persona.id ? "on" : ""} disabled={down} tabIndex={fits.value ? undefined : -1}
            onClick={() => choose(persona.id)}>
            {persona.name}
          </button>
        ))}
      </div>
      {!fits.value && (
        <label class="persona-menu">
          <span aria-hidden="true">{name ?? "No persona"} <span class="caret">▾</span></span>
          <select aria-label="Persona" disabled={down} value={picked ?? ""}
            onChange={(e) => choose((e.currentTarget as HTMLSelectElement).value)}>
            <option value="">No persona</option>
            {personas.map((persona) => <option key={persona.id} value={persona.id}>{persona.name}</option>)}
          </select>
        </label>
      )}
    </div>
  );
}

function FolderSwitch({ store, host, folder, folderName, down }: {
  store: Store; host: string; folder: string; folderName: string; down: boolean;
}) {
  const folders = orderedFolders(store.hosts.value, store.folders.value, store.macHostID.value);
  const at = folders.findIndex((p) => p.host.id === host && folderKey(p.folder.folder.folder) === folderKey(folder));
  if (folders.length < 2 || at < 0) return <h1>{folderName}</h1>;
  return (
    <h1 class="folder-switch" title="Start it in another folder">
      <span aria-hidden="true">{folderLabel(folders[at]!.host, folders[at]!.folder, store.macHostID.value)} <span class="caret">▾</span></span>
      <select aria-label="Folder" disabled={down} value={String(at)}
        onChange={(e) => {
          const picked = folders[Number((e.currentTarget as HTMLSelectElement).value)];
          if (picked) go({ host: picked.host.id, folder: picked.folder.folder.folder, compose: true });
        }}>
        {folders.map(({ host: h, folder: p }, i) => <option key={`${h.id}|${p.folder.folder}`} value={String(i)}>{folderLabel(h, p, store.macHostID.value)}</option>)}
      </select>
    </h1>
  );
}
