// A project's Connectors set-up (#1336, frames A, C, F and G), the one Connect GitHub sheet
// (frame B) and Your Connectors ▸ Connections (frame E), as the window's ConnectorSetupView,
// ConnectGitHubSheet and YourConnectionsView. The state is the host's, so all three clients
// show the same ticks. The page draws the Mac's grid; Where agents run says the other
// providers are set up on the Mac, since Providers is a Mac-only page by design.
import { useEffect, useState } from "preact/hooks";
import type { Store } from "../model/store";
import type {
  Connection, ConnectionSignIn, ConnectorSetup, ConnectorSetupReading, ConnectorSlot, ConnectorSlotKind, UUID,
} from "../protocol/generated";
import { projectPath } from "../model/hostedMCP";
import * as words from "../model/connectorSetup";
import { Modal } from "./Modal";

function why(e: unknown): string {
  if (e && typeof e === "object" && "message" in e) return String((e as { message: unknown }).message);
  return String(e);
}

function openOut(address: string) {
  window.open(address, "_blank", "noopener");
}

/** The set-up at the top of a project's Connectors page. */
export function ConnectorSetupSection({ store, host, folder, projectName, go }: {
  store: Store; host: string; folder: string; projectName: string;
  /** Opens a workflow of this project. */
  go: (workflowID: string) => void;
}) {
  const [setup, setSetup] = useState<ConnectorSetup>();
  const [problem, setProblem] = useState<string>();
  const [reading, setReading] = useState(false);
  const [connecting, setConnecting] = useState(false);
  const path = projectPath(folder);

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
    // Back from github.com (an install, a grant): read again.
    const back = () => { if (document.visibilityState === "visible") void load("cached"); };
    document.addEventListener("visibilitychange", back);
    return () => document.removeEventListener("visibilitychange", back);
  }, [host, path]);

  return (
    <div class="connector-setup">
      <p class="hint">{words.intro(projectName, setup?.repository)}</p>
      {problem && <p class="small failure">{problem}</p>}
      {setup && (
        <>
          <ConnectionCard setup={setup} connect={() => setConnecting(true)} />
          <h2 class="setup-heading">{words.setUpHeading(setup)}</h2>
          <div class="slot-grid">
            {setup.slots.map((slot) => (
              <SlotCard key={slot.slot} slot={slot} setup={setup} projectName={projectName} reading={reading}
                tryAgain={() => void load("fresh")} skip={(s) => void skip(slot.slot, s)} />
            ))}
          </div>
          {(setup.connection || setup.events.state !== "off") && (
            <>
              <h2 class="setup-heading">Events</h2>
              <div class="setup-card">
                <p>
                  {words.eventsLead(setup.events)}{" "}
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
        <ConnectGitHubDialog store={store} host={host} folder={path}
          connected={() => void load("fresh")} close={() => setConnecting(false)} />
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
        <a class="small" href="#/a/mcp">Manage in Your Connectors…</a>
      </div>
    );
  }
  return (
    <div class="setup-card connection">
      <span class="connector-mark" aria-hidden="true">GH</span>
      <div class="grow">
        <p class="strong">{c?.state === "signInAgain" ? "GitHub asks you to connect again." : words.connectTitle}</p>
        <p class="quiet small">{words.connectNote}</p>
      </div>
      <button class="prominent" onClick={connect}>{words.connectButton}</button>
    </div>
  );
}

function SlotMark({ slot, reading }: { slot: ConnectorSlot; reading: boolean }) {
  const label = {
    read: "Read", failed: "Couldn't read", refused: "Refused", skipped: "Skipped", notRead: "Reading",
    notConnected: "Not connected", noRemote: "No GitHub remote",
  }[slot.state];
  const mark = slot.state === "read" ? "✓"
    : slot.state === "failed" || slot.state === "refused" ? "!"
    : slot.state === "notRead" && reading ? "…" : "";
  return <span class={`slot-mark ${slot.state}`} role="img" aria-label={label}>{mark}</span>;
}

function SlotCard({ slot, setup, projectName, reading, tryAgain, skip }: {
  slot: ConnectorSlot; setup: ConnectorSetup; projectName: string; reading: boolean;
  tryAgain: () => void; skip: (skipped: boolean) => void;
}) {
  const [changing, setChanging] = useState(false);
  const canChange = slot.slot !== "workspace" && ["read", "refused", "failed"].includes(slot.state);
  const proof = slot.proof;
  return (
    <div class={`setup-card slot ${changing ? "changing" : ""}`} aria-label={`${words.heading(slot.slot)}: ${words.title(slot)}`}>
      <p class="slot-head">
        <SlotMark slot={slot} reading={reading} />
        <span class="slot-kind">{words.heading(slot.slot)}</span>
        {canChange && !changing && <button class="link small" onClick={() => setChanging(true)}>Change…</button>}
      </p>
      <p class="strong">{words.title(slot)}</p>
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
          {words.line(slot, projectName, setup.repository, false)}
        </p>
      )}
      <p class="slot-actions small">
        {(slot.state === "notConnected" || slot.state === "noRemote") && slot.slot === "tasks" && (
          <span class="quiet">Linear and other trackers: Add Connector on the Mac.</span>
        )}
        {(slot.state === "notConnected" || slot.state === "noRemote") && <button class="link" onClick={() => skip(true)}>Skip</button>}
        {slot.state === "failed" && <button onClick={tryAgain}>Try Again</button>}
        {slot.state === "refused" && (
          <>
            {setup.installURL && <button onClick={() => openOut(setup.installURL!)}>Grant on github.com</button>}
            <button onClick={tryAgain}>Try Again</button>
          </>
        )}
        {slot.state === "skipped" && <button class="link" onClick={() => skip(false)}>Set Up</button>}
      </p>
      {changing && (
        <div class="slot-change">
          <button onClick={() => setChanging(false)}>{slot.choice}</button>
          <button onClick={() => { skip(true); setChanging(false); }}>None (skip)</button>
          <button class="link" onClick={() => setChanging(false)}>Cancel</button>
        </div>
      )}
    </div>
  );
}

/** Connect GitHub (frame B): the host's device flow, with the code, in a sheet. */
export function ConnectGitHubDialog({ store, host, folder, connected, close }: {
  store: Store; host: string; folder?: string; connected: () => void; close: () => void;
}) {
  type Step = { kind: "asking" } | { kind: "starting" } | { kind: "waiting"; flow: ConnectionSignIn }
    | { kind: "install"; login: string; repository: string; url: string } | { kind: "failed"; why: string };
  const [step, setStep] = useState<Step>({ kind: "asking" });
  const [flowID, setFlowID] = useState<UUID>();

  useEffect(() => () => {
    // Closed while GitHub was still out: the host stops polling for it.
    if (flowID) void store.link.call("connections/sign-in/cancel", { flowID }, host).catch(() => null);
  }, [flowID]);

  const start = async () => {
    setStep({ kind: "starting" });
    let flow: ConnectionSignIn;
    try {
      flow = await store.link.call("connections/sign-in", { provider: "github" }, host);
    } catch (e) {
      setStep({ kind: "failed", why: why(e) });
      return;
    }
    setFlowID(flow.flowID);
    setStep({ kind: "waiting", flow });
    void navigator.clipboard?.writeText(flow.userCode).catch(() => null);
    openOut(flow.verificationURL);
    for (;;) {
      try {
        flow = await store.link.call("connections/sign-in/wait", { flowID: flow.flowID }, host);
      } catch (e) {
        setStep({ kind: "failed", why: why(e) });
        return;
      }
      if (flow.status === "waiting") continue;
      setFlowID(undefined);
      if (flow.status === "connected") {
        connected();
        if (folder) {
          const setup = await store.link.call("connectors/setup", { folder, reading: "fresh" }, host).catch(() => null);
          if (setup?.installed === false && setup.repository && setup.installURL) {
            setStep({ kind: "install", login: flow.connection?.login ?? "you", repository: setup.repository, url: setup.installURL });
            return;
          }
        }
        close();
        return;
      }
      if (flow.status === "cancelled") return;
      setStep({ kind: "failed", why: words.sheetStatus(flow) });
      return;
    }
  };

  return (
    <Modal label="Connect GitHub" close={close}>
      <div class="sheet-body connect-sheet">
        <div class="connection">
          <span class="connector-mark" aria-hidden="true">GH</span>
          <div>
            <p class="strong">Connect GitHub</p>
            <p class="quiet small">{words.sheetSubtitle}</p>
          </div>
        </div>
        <h2 class="setup-heading">Agents will be able to</h2>
        <ul class="abilities">{words.abilities.map((a) => <li key={a}>{a}</li>)}</ul>
        <p class="quiet small">{words.sheetChoose}</p>
        {step.kind === "starting" && <p class="quiet small">Asking GitHub for a code…</p>}
        {step.kind === "waiting" && (
          <div class="sign-in-code">
            <p><span class="quiet small">Your code</span> <code class="user-code">{step.flow.userCode}</code>{" "}
              <button onClick={() => void navigator.clipboard?.writeText(step.flow.userCode)}>Copy</button></p>
            <p class="small">{words.sheetStatus(step.flow)}</p>
            <button class="link small" onClick={() => openOut(step.flow.verificationURL)}>Open github.com Again</button>
          </div>
        )}
        {step.kind === "install" && (
          <div class="sign-in-code">
            <p class="strong">Connected as {step.login}.</p>
            <p class="small">{words.notInstalled(step.repository)} Install it there, then come back.</p>
          </div>
        )}
        {step.kind === "failed" && <p class="small failure">{step.why}</p>}
        <div class="sheet-actions">
          <span class="quiet small grow">{words.sheetFoot}</span>
          {step.kind === "install" ? (
            <>
              <button onClick={close}>Done</button>
              <button class="prominent" onClick={() => { if (step.kind === "install") openOut(step.url); close(); }}>Install on github.com</button>
            </>
          ) : (
            <>
              <button onClick={close}>Cancel</button>
              {step.kind === "asking" && <button class="prominent" onClick={() => void start()}>{words.continueButton}</button>}
              {step.kind === "failed" && <button class="prominent" onClick={() => void start()}>Try Again</button>}
            </>
          )}
        </div>
      </div>
    </Modal>
  );
}

/** Activity ▸ Your Connectors: Connections, with Disconnect (frame E). */
export function YourConnections({ store, host }: { store: Store; host: string }) {
  const [connections, setConnections] = useState<Connection[]>();
  const [problem, setProblem] = useState<string>();
  const [connecting, setConnecting] = useState(false);
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
    if (!window.confirm(`Disconnect ${words.connectionTitle(c)}? ${words.disconnectNote}`)) return;
    try {
      const answer = await store.link.call("connections/disconnect", { provider: c.provider }, host);
      setProblem(answer.error);
    } catch (e) {
      setProblem(why(e));
    }
    await load();
  };
  const githubConnected = connections?.some((c) => c.provider === "github" && c.state === "connected");
  return (
    <div class="connections">
      <p class="setup-row">
        <span class="setup-heading grow">Connections</span>
        {connections && !githubConnected && <button onClick={() => setConnecting(true)}>Connect…</button>}
      </p>
      {problem && <p class="small failure">{problem}</p>}
      <ul class="setup-card list">
        {connections?.length === 0 && <li class="quiet">No connections yet. Connect GitHub to give agents issues, pull requests and Actions in every project.</li>}
        {connections?.map((c) => (
          <li key={c.provider} class="connection">
            <span class="connector-mark soft" aria-hidden="true">{(c.login ?? "G").slice(0, 1).toUpperCase()}</span>
            <div class="grow">
              <p class="strong">{words.connectionTitle(c)}</p>
              <p class={`small ${c.state === "signInAgain" ? "attention" : "quiet"}`}>{words.connectionNote(c)}</p>
            </div>
            {c.state === "signInAgain"
              ? <button onClick={() => setConnecting(true)}>Connect Again…</button>
              : c.installURL && <button class="link small" onClick={() => openOut(c.installURL!)}>Repositories on github.com</button>}
            <button class="destructive" onClick={() => void disconnect(c)}>Disconnect</button>
          </li>
        ))}
      </ul>
      {connecting && <ConnectGitHubDialog store={store} host={host} connected={() => void load()} close={() => setConnecting(false)} />}
    </div>
  );
}
