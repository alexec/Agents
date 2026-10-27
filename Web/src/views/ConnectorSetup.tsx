// A folder's Connectors set-up (#1336, frames A, C, F and G), the one Connect sheet for GitHub
// (frame B) and Linear (#1343, frame H), and Connectors ▸ Connections (frame E), as the
// window's ConnectorSetupView, ConnectGitHubSheet and YourConnectionsView. The state is the host's, so all three clients
// show the same ticks. The page draws the Mac's grid; Where agents run says the machine the
// folder is on, and has Add a Machine… and Add Provider… in place (#2131).
import { useEffect, useRef, useState } from "preact/hooks";
import type { Store } from "../model/store";
import type {
  Connection, ConnectionProvider, ConnectionSignIn, ConnectorSetup, ConnectorSetupReading, ConnectorSlot, ConnectorSlotKind, UUID,
} from "../protocol/generated";
import { folderPath } from "../model/hostedMCP";
import { Capability } from "../protocol/capabilities.generated";
import * as words from "../model/connectorSetup";
import { projectSlotFrom, projectWords, setByProject, slotLine, slotsOwner } from "../model/projects";
import type { Project } from "../protocol/generated";
import { addMachineWords, whereAgentsRun } from "../model/addMachine";
import { Modal } from "./Modal";
import { AddMachineDialog } from "./AddMachineDialog";

function why(e: unknown): string {
  if (e && typeof e === "object" && "message" in e) return String((e as { message: unknown }).message);
  return String(e);
}

function openOut(address: string) {
  window.open(address, "_blank", "noopener");
}

/** The set-up at the top of a folder's Connectors page. */
export function ConnectorSetupSection({ store, host, folder, folderName, go }: {
  store: Store; host: string; folder: string; folderName: string;
  /** Opens a workflow of this folder. */
  go: (workflowID: string) => void;
}) {
  const [setup, setSetup] = useState<ConnectorSetup>();
  const [problem, setProblem] = useState<string>();
  const [reading, setReading] = useState(false);
  const [connecting, setConnecting] = useState<ConnectionProvider>();
  /** Whether the person's Linear connection is there, for the Tasks slot (#1682); unknown until read. */
  const [linearConnected, setLinearConnected] = useState<boolean>();
  const path = folderPath(folder);
  /** Add a Machine… or Add Provider…, in place (#2131). */
  const [adding, setAdding] = useState<"machine" | "provider">();
  useEffect(() => { if (store.providers.list.peek() === null) void store.providers.load(); }, []);
  // Where agents run (#2131): the machine the folder is on, and what else is yours.
  const hosts = store.hosts.value.filter((h) => h.relay == null);
  const place = {
    title: whereAgentsRun.title(false, hosts.find((h) => h.id === host)?.name),
    line: whereAgentsRun.line(hosts.filter((h) => h.id !== host).map((h) => h.name),
      (store.providers.list.value ?? []).map((p) => p.name)),
  };

  const readLinear = async () => {
    try {
      const { connections } = await store.link.call("connections/list", {}, host);
      setLinearConnected(connections.some((c) => c.provider === "linear" && c.state === "connected"));
    } catch {
      // Unknown: the slot says what it said before.
    }
  };

  const load = async (how: ConnectorSetupReading) => {
    setReading(true);
    try {
      setSetup(await store.link.call("connectors/setup", { folder: path, reading: how }, host));
      setProblem(undefined);
    } catch (e) {
      setProblem(why(e));
    } finally {
      setReading(false);
    }
  };
  const skip = async (slot: ConnectorSlotKind, skipped: boolean) => {
    try {
      setSetup(await store.link.call("connectors/setup/skip", { folder: path, slot, skipped }, host));
      setProblem(undefined);
    } catch (e) {
      setProblem(why(e));
    }
  };
  useEffect(() => {
    void load("cached");
    void readLinear();
    // Back from github.com (an install, a grant): read again.
    const back = () => { if (document.visibilityState === "visible") { void load("cached"); void readLinear(); } };
    document.addEventListener("visibilitychange", back);
    return () => document.removeEventListener("visibilitychange", back);
  }, [host, path]);

  return (
    <div class="connector-setup">
      <p class="hint">{words.intro(folderName, setup?.repository, setup?.site)}</p>
      {problem && <p class="small failure">{problem}</p>}
      {setup && (
        <>
          <ConnectionCard setup={setup} connect={() => setConnecting(words.forgeOf(setup))} />
          <h2 class="setup-heading">{words.setUpHeading(setup)}</h2>
          <div class="slot-grid">
            {setup.slots.map((slot) => (
              <SlotCard key={slot.slot} slot={slot} setup={setup} folderName={folderName} reading={reading}
                tryAgain={() => void load("fresh")} skip={(s) => void skip(slot.slot, s)}
                linearConnected={linearConnected} connectLinear={() => setConnecting("linear")}
                place={place} admin={store.person.value?.role !== "member"} add={setAdding} />
            ))}
          </div>
          {setup.project && <ProjectSlots store={store} setup={setup} changed={() => void load("cached")} />}
          {(setup.connection || setup.events.state !== "off") && (
            <>
              <h2 class="setup-heading">Events</h2>
              <div class="setup-card">
                <p>
                  {words.eventsLead(setup.events, words.forgeOf(setup))}{" "}
                  {setup.events.state === "on" && <code title={setup.events.names.join(", ")}>{words.eventNouns(setup.events.names).join(" ")}</code>}
                </p>
                {setup.events.state === "on" && (
                  <p class="quiet small">
                    {words.workflowsLead(setup.events)}{" "}
                    {setup.events.workflows.map((w, i) => (
                      <span key={w.id}>
                        <button class="link" onClick={() => go(w.id)}>{w.name}</button>
                        {i < setup.events.workflows.length - 1 ? ", " : "."}
                      </span>
                    ))}
                  </p>
                )}
              </div>
            </>
          )}
        </>
      )}
      {!setup && !problem && <p class="quiet small">Reading…</p>}
      {connecting && (
        <ConnectDialog store={store} host={host} provider={connecting} folder={path}
          connected={() => void (connecting === "linear" ? readLinear() : load("fresh"))}
          close={() => setConnecting(undefined)} />
      )}
      {adding && (
        <AddMachineDialog store={store} start={adding === "provider" ? { kind: "addProvider" } : { kind: "choose" }}
          close={() => setAdding(undefined)} />
      )}
    </div>
  );
}

function ConnectionCard({ setup, connect }: { setup: ConnectorSetup; connect: () => void }) {
  const c = setup.connection;
  if (c && c.state === "connected") {
    return (
      <div class="setup-card connection">
        <span class="connector-mark soft" aria-hidden="true">{(c.login ?? "G").slice(0, 1).toUpperCase()}</span>
        <div class="grow">
          <p class="strong">{words.connected(c)}</p>
          <p class="quiet small">{words.connectedNote(setup)}</p>
          {setup.installed === false && setup.repository && (
            <p class="small attention">
              {words.notInstalled(setup.repository)}{" "}
              {setup.installURL && <button class="link" onClick={() => openOut(setup.installURL!)}>Install on github.com</button>}
            </p>
          )}
        </div>
        <a class="small" href="#/a/mcp">Manage in Connectors…</a>
      </div>
    );
  }
  const forge = words.forgeOf(setup);
  return (
    <div class="setup-card connection">
      <span class="connector-mark" aria-hidden="true">{words.letters(forge)}</span>
      <div class="grow">
        <p class="strong">{c?.state === "signInAgain" ? words.connectAgain(forge) : words.connectTitleFor(forge)}</p>
        <p class="quiet small">{words.connectNoteFor(forge)}</p>
      </div>
      <button class="prominent" onClick={connect}>{words.connectButtonFor(forge)}</button>
    </div>
  );
}

function SlotMark({ slot, reading }: { slot: ConnectorSlot; reading: boolean }) {
  const label = {
    read: "Read", failed: "Couldn't read", refused: "Refused", skipped: "Skipped", notRead: "Reading",
    notConnected: "Not connected", noRemote: words.noRemote,
  }[slot.state];
  const mark = slot.state === "read" ? "✓"
    : slot.state === "failed" || slot.state === "refused" ? "!"
    : slot.state === "notRead" && reading ? "…" : "";
  return <span class={`slot-mark ${slot.state}`} role="img" aria-label={label}>{mark}</span>;
}

function SlotCard({ slot, setup, folderName, reading, tryAgain, skip, linearConnected, connectLinear, place, admin, add }: {
  slot: ConnectorSlot; setup: ConnectorSetup; folderName: string; reading: boolean;
  tryAgain: () => void; skip: (skipped: boolean) => void;
  /** Tasks only: whether Linear is connected, unknown until read (#1682). */
  linearConnected: boolean | undefined; connectLinear: () => void;
  /** Where agents run only (#2131): its machine and line, and Add a Machine… or Add Provider…. */
  place: { title: string; line: string }; admin: boolean; add: (what: "machine" | "provider") => void;
}) {
  const [changing, setChanging] = useState(false);
  const workspace = slot.slot === "workspace";
  const fromProject = slot.fromProject === true;
  const canChange = workspace || (!fromProject && ["read", "refused", "failed"].includes(slot.state));
  const proof = slot.proof;
  const title = workspace ? place.title : words.title(slot);
  return (
    <div class={`setup-card slot ${changing ? "changing" : ""}`} aria-label={`${words.heading(slot.slot)}: ${title}`}>
      <p class="slot-head">
        <SlotMark slot={slot} reading={reading} />
        <span class="slot-kind">{words.heading(slot.slot)}</span>
        {canChange && !changing && <button class="link small" onClick={() => setChanging(true)}>Change…</button>}
      </p>
      <p class="strong">{title}</p>
      {proof ? (
        <p class="quiet small">
          {words.proofLead(slot.slot)}:{" "}
          {proof.number != null && (proof.url
            ? <a href={proof.url} target="_blank" rel="noopener">#{proof.number}</a>
            : <>#{proof.number}</>)}{" "}
          {words.proofText(proof)}
        </p>
      ) : (
        <p class={`small ${["failed", "refused", "noRemote"].includes(slot.state) ? "attention" : "quiet"}`}>
          {workspace ? place.line : words.line(slot, folderName, setup.repository, false, words.forgeOf(setup))}
        </p>
      )}
      {fromProject && <p class="quiet small">{setByProject(setup.projectName ?? projectWords.title)}</p>}
      <p class="slot-actions small">
        {(slot.state === "notConnected" || slot.state === "noRemote") && slot.slot === "tasks" && (
          <>
            {linearConnected === false && <button class="link" onClick={connectLinear}>{words.connectLinear}</button>}
            <span class="quiet">{words.otherTrackers(linearConnected !== false)}</span>
          </>
        )}
        {!fromProject && (slot.state === "notConnected" || slot.state === "noRemote") && <button class="link" onClick={() => skip(true)}>Skip</button>}
        {slot.state === "failed" && <button onClick={tryAgain}>Try Again</button>}
        {slot.state === "refused" && (
          <>
            {words.grantURL(setup) && <button onClick={() => openOut(words.grantURL(setup)!)}>{words.grantButton(setup)}</button>}
            <button onClick={tryAgain}>Try Again</button>
          </>
        )}
        {!fromProject && slot.state === "skipped" && <button class="link" onClick={() => skip(false)}>Set Up</button>}
      </p>
      {changing && workspace && (
        <div class="slot-change">
          <button title={whereAgentsRun.hereNote} onClick={() => setChanging(false)}>{place.title}</button>
          <button title={whereAgentsRun.addMachineNote} onClick={() => { add("machine"); setChanging(false); }}>{addMachineWords.menuItem}</button>
          {admin && (
            <button title={whereAgentsRun.addProviderNote} onClick={() => { add("provider"); setChanging(false); }}>{addMachineWords.addProvider}</button>
          )}
          {words.forgeOf(setup) === "github" && setup.repository && setup.connection?.state === "connected" && (
            <p class="quiet small">GitHub Codespaces: Set up on the Mac.</p>
          )}
          <button class="link" onClick={() => setChanging(false)}>Cancel</button>
          <p class="quiet small">{addMachineWords.providersYours}</p>
        </div>
      )}
      {changing && !workspace && (
        <div class="slot-change">
          <button onClick={() => setChanging(false)}>{slot.choice}</button>
          {slot.slot === "tasks" && linearConnected === false && (
            <button onClick={() => { connectLinear(); setChanging(false); }}>{words.connectLinear}</button>
          )}
          <button onClick={() => { skip(true); setChanging(false); }}>None (skip)</button>
          <button class="link" onClick={() => setChanging(false)}>Cancel</button>
        </div>
      )}
    </div>
  );
}

/**
 * The folder's project's tools (#2669), as the window's ProjectSlotsCard: Tasks, Code review and
 * CI are the project's, and its owner or an admin makes a folder's own slot the project's, or
 * gives one back to each folder.
 */
function ProjectSlots({ store, setup, changed }: { store: Store; setup: ConnectorSetup; changed: () => void }) {
  const [project, setProject] = useState<Project>();
  const [problem, setProblem] = useState<string>();
  const [asking, setAsking] = useState(false);
  useEffect(() => {
    void store.link.call("projects/list", {}).then((l) => setProject(l.projects.find((p) => p.id === setup.project)))
      .catch(() => setProject(undefined));
  }, [setup.project]);
  const name = project?.name ?? setup.projectName ?? projectWords.title;
  const set = async (slot: ConnectorSlotKind, value: ReturnType<typeof projectSlotFrom>) => {
    if (!setup.project) return;
    setAsking(true);
    try {
      setProject(await store.link.call("projects/setSlot", { id: setup.project, slot, ...(value ? { value } : {}) }));
      setProblem(undefined);
      // The machine hears it from the control plane (host/projects): give it a moment.
      setTimeout(changed, 400);
    } catch (e) {
      setProblem(why(e));
    } finally {
      setAsking(false);
    }
  };
  return (
    <div class="setup-card project-slots">
      <p class="quiet small">{slotsOwner(name)}</p>
      {project?.mayChange && setup.slots.filter((s) => s.slot !== "workspace").map((slot) => {
        const value = projectSlotFrom(setup, slot);
        return (
          <p key={slot.slot} class="small project-slot">
            <span class="slot-kind">{words.heading(slot.slot)}</span>{" "}
            <span>{slotLine(slot, name)}</span>{" "}
            {slot.fromProject
              ? <button class="link" disabled={asking} onClick={() => void set(slot.slot, undefined)}>{projectWords.useFolderOwn}</button>
              : value && <button class="link" disabled={asking} onClick={() => void set(slot.slot, value)}>{projectWords.useForProject}</button>}
          </p>
        );
      })}
      {problem && <p class="small failure">{problem}</p>}
    </div>
  );
}

/** The name of the window that the Linear sign-in opens, so the hand-back page has an opener. */
const signInWindow = "agents-sign-in";

/**
 * Connect GitHub (frame B): the host's device flow, with the code, in a sheet. Connect Linear
 * (frame H): the same sheet. The host gives an authorize address; the page opens it in a window,
 * and the hand-back page sends the code back here by postMessage. Connect GitLab (#1630): the
 * device flow on gitlab.com, or an access token on any GitLab, which goes to the host only.
 * Connect Email (#1780): an IMAP server, a user and an app password, which go to the host only.
 */
export function ConnectDialog({ store, host, provider, folder, again, connected, close }: {
  store: Store; host: string; provider: ConnectionProvider; folder?: string;
  /** The ended connection Connect Again… is for: GitLab's opens the way it was made, with its address (#1865). */
  again?: Connection | undefined; connected: () => void; close: () => void;
}) {
  const opening = provider === "gitlab" && again ? words.gitlabAgain(again) : undefined;
  type Step = { kind: "asking" } | { kind: "starting" } | { kind: "waiting"; flow: ConnectionSignIn }
    | { kind: "finishing" } | { kind: "install"; login: string; repository: string; url: string }
    | { kind: "checking" } | { kind: "failed"; why: string };
  const [step, setStep] = useState<Step>({ kind: "asking" });
  /** GitLab only (#1630): an access token instead of the sign-in, for a self-managed GitLab. */
  const [withToken, setWithToken] = useState(opening?.withToken ?? false);
  const [address, setAddress] = useState(opening?.address ?? "");
  const [token, setToken] = useState("");
  /** Email only (#1780). The app password stays in this state, and is cleared after the sign-in. */
  const [server, setServer] = useState("");
  const [user, setUser] = useState("");
  const [password, setPassword] = useState("");
  const isEmail = provider === "email";
  const busy = step.kind === "starting" || step.kind === "waiting" || step.kind === "finishing" || step.kind === "checking";
  const [flowID, setFlowID] = useState<UUID>();
  /** Removes the message listener of the sign-in under way. */
  const stopListening = useRef<(() => void) | undefined>(undefined);
  const providerName = words.name(provider);

  useEffect(() => () => {
    // Closed while the provider was still out: the host stops polling for it.
    if (flowID) void store.link.call("connections/sign-in/cancel", { flowID }, host).catch(() => null);
  }, [flowID]);
  useEffect(() => () => stopListening.current?.(), []);

  const start = async () => {
    stopListening.current?.();
    // Open the window now, in the click, so that the browser does not block it. Without
    // noopener: the hand-back page sends the code to its opener.
    const popup = provider === "linear" ? window.open("about:blank", signInWindow) : null;
    setStep({ kind: "starting" });
    let flow: ConnectionSignIn;
    try {
      flow = await store.link.call("connections/sign-in",
        provider === "linear" ? { provider, origin: location.origin } : { provider }, host);
    } catch (e) {
      popup?.close();
      setStep({ kind: "failed", why: why(e) });
      return;
    }
    setFlowID(flow.flowID);
    setStep({ kind: "waiting", flow });
    // The first answer that ends the sign-in wins: the hand-back page's code, or the long poll
    // (another client can finish the sign-in too).
    let over = false;
    const end = async (done: ConnectionSignIn) => {
      if (over) return;
      over = true;
      stopListening.current?.();
      setFlowID(undefined);
      if (done.status === "connected") {
        connected();
        if (folder && provider === "github") {
          const setup = await store.link.call("connectors/setup", { folder, reading: "fresh" }, host).catch(() => null);
          if (setup?.installed === false && setup.repository && setup.installURL) {
            setStep({ kind: "install", login: done.connection?.login ?? "you", repository: setup.repository, url: setup.installURL });
            return;
          }
        }
        close();
        return;
      }
      if (done.status === "cancelled") return;
      setStep({ kind: "failed", why: words.sheetStatus(done) });
    };
    const fail = (e: unknown) => {
      if (over) return;
      over = true;
      stopListening.current?.();
      setStep({ kind: "failed", why: why(e) });
    };

    if (flow.grant === "authorizationCode") {
      const id = flow.flowID;
      const state = words.authorizeState(flow.verificationURL);
      const listen = (event: MessageEvent) => {
        const answer = words.oauthCallback(event, id, state);
        if (!answer || over) return;
        stopListening.current?.();
        setStep({ kind: "finishing" });
        store.link.call("connections/sign-in/complete", answer, host)
          .then((done) => { if (done.status !== "waiting") void end(done); }, fail);
      };
      window.addEventListener("message", listen);
      stopListening.current = () => {
        window.removeEventListener("message", listen);
        stopListening.current = undefined;
      };
      if (popup && !popup.closed) popup.location.href = flow.verificationURL;
      else window.open(flow.verificationURL, signInWindow);
    } else {
      if (flow.userCode) void navigator.clipboard?.writeText(flow.userCode).catch(() => null);
      openOut(flow.verificationURL);
    }
    for (;;) {
      try {
        flow = await store.link.call("connections/sign-in/wait", { flowID: flow.flowID }, host);
      } catch (e) {
        fail(e);
        return;
      }
      if (over) return;
      if (flow.status === "waiting") continue;
      await end(flow);
      return;
    }
  };

  const connectWithToken = async () => {
    const typed = token.trim();
    if (!typed || busy) return;
    setStep({ kind: "checking" });
    const url = address.trim();
    try {
      const answer = await store.link.call("connections/sign-in/token", url ? { provider, url, token: typed } : { provider, token: typed }, host);
      if (answer.connection) {
        setToken("");
        connected();
        close();
        return;
      }
      setStep({ kind: "failed", why: answer.error ?? "GitLab did not take the token." });
    } catch (e) {
      setStep({ kind: "failed", why: why(e) });
    }
  };

  const connectWithEmail = async () => {
    const request = words.emailRequest(server, user, password);
    if (!request || busy) return;
    setStep({ kind: "checking" });
    try {
      const answer = await store.link.call("connections/sign-in/email", request, host);
      if (answer.connection) {
        setPassword("");
        connected();
        close();
        return;
      }
      setStep({ kind: "failed", why: answer.error || words.email.failed });
    } catch (e) {
      setStep({ kind: "failed", why: why(e) });
    }
  };

  const openAgain = (flow: ConnectionSignIn) => {
    if (flow.grant === "authorizationCode") window.open(flow.verificationURL, signInWindow);
    else openOut(flow.verificationURL);
  };

  return (
    <Modal label={`Connect ${providerName}`} close={close}>
      <div class="sheet-body connect-sheet">
        <div class="connection">
          <span class="connector-mark" aria-hidden="true">{words.letters(provider)}</span>
          <div>
            <p class="strong">Connect {providerName}</p>
            <p class="quiet small">{words.sheetSubtitleFor(provider)}</p>
          </div>
        </div>
        {provider === "gitlab" && (
          <div class="segmented" role="radiogroup" aria-label="Connect with">
            {([false, true] as const).map((t) => (
              <button key={String(t)} type="button" role="radio" aria-checked={withToken === t} class={withToken === t ? "on" : ""}
                disabled={busy} onClick={() => { setWithToken(t); if (step.kind === "failed") setStep({ kind: "asking" }); }}>
                {t ? words.gitlab.tokenWay : words.gitlab.signInWay}
              </button>
            ))}
          </div>
        )}
        <h2 class="setup-heading">Agents will be able to</h2>
        <ul class="abilities">{words.abilitiesFor(provider).map((a) => <li key={a}>{a}</li>)}</ul>
        {withToken && (
          <form id="connect-token" class="token-form" onSubmit={(e) => { e.preventDefault(); void connectWithToken(); }}>
            <p class="small">{words.gitlab.tokenIntro}</p>
            <label>{words.gitlab.addressLabel}
              <input type="url" value={address} placeholder={words.gitlab.addressPrompt} disabled={busy}
                autocomplete="off" autocapitalize="off" spellcheck={false}
                onInput={(e) => setAddress((e.target as HTMLInputElement).value)} />
            </label>
            <label>{words.gitlab.tokenLabel}
              <input type="password" value={token} placeholder={words.gitlab.tokenPrompt} disabled={busy} autocomplete="off"
                onInput={(e) => setToken((e.target as HTMLInputElement).value)} />
            </label>
            <button type="button" class="link small" onClick={() => openOut(words.newGitLabTokenURL(address))}>Make a Token on GitLab</button>
          </form>
        )}
        {isEmail && (
          <form id="connect-email" class="token-form" onSubmit={(e) => { e.preventDefault(); void connectWithEmail(); }}>
            <p class="small">{words.email.intro}</p>
            <label>{words.email.serverLabel}
              <input type="text" value={server} placeholder={words.email.serverPrompt} disabled={busy}
                autocomplete="off" autocapitalize="off" spellcheck={false}
                onInput={(e) => setServer((e.target as HTMLInputElement).value)} />
            </label>
            <label>{words.email.userLabel}
              <input type="email" value={user} placeholder={words.email.userPrompt} disabled={busy}
                autocomplete="username" autocapitalize="off" spellcheck={false}
                onInput={(e) => setUser((e.target as HTMLInputElement).value)} />
            </label>
            <label>{words.email.passwordLabel}
              <input type="password" value={password} placeholder={words.email.passwordPrompt} disabled={busy} autocomplete="current-password"
                onInput={(e) => setPassword((e.target as HTMLInputElement).value)} />
            </label>
          </form>
        )}
        <p class="quiet small">{words.sheetChooseFor(provider)}</p>
        {step.kind === "starting" && (
          <p class="quiet small">{provider === "linear" ? "Starting the sign-in…" : `Asking ${providerName} for a code…`}</p>
        )}
        {step.kind === "waiting" && (
          <div class="sign-in-code">
            {step.flow.userCode && (
              <p><span class="quiet small">Your code</span> <code class="user-code">{step.flow.userCode}</code>{" "}
                <button onClick={() => void navigator.clipboard?.writeText(step.flow.userCode!)}>Copy</button></p>
            )}
            <p class="small">{words.sheetStatus(step.flow)}</p>
            <button class="link small" onClick={() => openAgain(step.flow)}>
              Open {words.site(step.flow.provider)} Again
            </button>
          </div>
        )}
        {step.kind === "finishing" && <p class="quiet small">{words.linear.finishing}</p>}
        {step.kind === "checking" && <p class="quiet small">{isEmail ? words.email.checking : words.gitlab.checking}</p>}
        {step.kind === "install" && (
          <div class="sign-in-code">
            <p class="strong">Connected as {step.login}.</p>
            <p class="small">{words.notInstalled(step.repository)} Install it there, then come back.</p>
          </div>
        )}
        {step.kind === "failed" && <p class="small failure">{step.why}</p>}
        <div class="sheet-actions">
          <span class="quiet small grow">{provider === "email" ? words.email.sheetFoot : words.sheetFoot}</span>
          {step.kind === "install" ? (
            <>
              <button onClick={close}>Done</button>
              <button class="prominent" onClick={() => { if (step.kind === "install") openOut(step.url); close(); }}>Install on github.com</button>
            </>
          ) : (
            <>
              <button onClick={close}>Cancel</button>
              {isEmail
                ? (step.kind === "asking" || step.kind === "failed") &&
                  <button type="submit" form="connect-email" class="prominent"
                    disabled={!words.emailRequest(server, user, password)}>{words.email.button}</button>
                : withToken
                ? (step.kind === "asking" || step.kind === "failed") &&
                  <button type="submit" form="connect-token" class="prominent" disabled={!token.trim()}>{words.gitlab.tokenButton}</button>
                : <>
                  {step.kind === "asking" && <button class="prominent" onClick={() => void start()}>{words.continueButtonFor(provider)}</button>}
                  {step.kind === "failed" && <button class="prominent" onClick={() => void start()}>Try Again</button>}
                </>}
            </>
          )}
        </div>
      </div>
    </Modal>
  );
}

/** Activity ▸ Connectors: Connections, with Disconnect (frame E), and a row to connect each provider that is not connected. */
export function YourConnections({ store, host }: { store: Store; host: string }) {
  const [connections, setConnections] = useState<Connection[]>();
  const [problem, setProblem] = useState<string>();
  const [connecting, setConnecting] = useState<ConnectionProvider>();
  /** The ended connection Connect Again… is for, so its dialog opens the way it was made. */
  const [again, setAgain] = useState<Connection>();
  const load = async () => {
    try {
      setConnections((await store.link.call("connections/list", {}, host)).connections);
      setProblem(undefined);
    } catch (e) {
      setConnections([]);
      setProblem(why(e));
    }
  };
  useEffect(() => { void load(); }, [host]);
  const disconnect = async (c: Connection) => {
    if (!window.confirm(`Disconnect ${words.connectionTitle(c)}? ${words.disconnectNoteFor(c.provider)}`)) return;
    try {
      const answer = await store.link.call("connections/disconnect", { provider: c.provider }, host);
      setProblem(answer.error);
    } catch (e) {
      setProblem(why(e));
    }
    await load();
  };
  // Email only on a host with connections.email/1 (#1780): an older host does not show it.
  const notConnected = connections ? words.providersFor(store.has(host, Capability.connectionsEmail1)).filter((p) => !connections.some((c) => c.provider === p)) : [];
  return (
    <div class="connections">
      <p class="setup-row">
        <span class="setup-heading grow">Connections</span>
      </p>
      {problem && <p class="small failure">{problem}</p>}
      <ul class="setup-card list">
        {connections?.map((c) => (
          <li key={c.provider} class="connection">
            <span class="connector-mark soft" aria-hidden="true">{(c.login ?? words.letters(c.provider)).slice(0, 1).toUpperCase()}</span>
            <div class="grow">
              <p class="strong">{words.connectionTitle(c)}</p>
              <p class={`small ${c.state === "signInAgain" ? "attention" : "quiet"}`}>{words.connectionNote(c)}</p>
            </div>
            {c.state === "signInAgain"
              ? <button onClick={() => { setAgain(c); setConnecting(c.provider); }}>Connect Again…</button>
              : c.provider === "github" && <button class="link small" onClick={() => openOut(words.installationsURL)}>Repositories on github.com</button>}
            <button class="destructive" onClick={() => void disconnect(c)}>Disconnect</button>
          </li>
        ))}
        {notConnected.map((p) => (
          <li key={p} class="connection">
            <span class="connector-mark" aria-hidden="true">{words.letters(p)}</span>
            <div class="grow">
              <p class="strong">{words.name(p)}</p>
              <p class="small quiet">{words.notConnectedNote(p)}</p>
            </div>
            <button onClick={() => { setAgain(undefined); setConnecting(p); }}>{words.connectButtonFor(p)}</button>
          </li>
        ))}
      </ul>
      {connecting && (
        <ConnectDialog store={store} host={host} provider={connecting} again={again} connected={() => void load()} close={() => setConnecting(undefined)} />
      )}
    </div>
  );
}
