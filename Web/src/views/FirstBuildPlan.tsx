// The plan page (#5054, spec 5048-first-build sections 4 to 7), as the Mac window's (#5053): after
// Submit on the question page, the whole page, still with no sidebar or toolbar. The idea as its
// title, the starter under it, the starter's task list with each task's state, and under the list
// the first-build session's chat. Open Agents takes it to the usual page.
//
// The first two tasks are the page's: it sets up the runtime and connects GitHub inline, on the
// machine the session will run on, then starts the agent with firstBuild/start. The agent's tasks
// are its plan, matched by their words. The page is a view of the session, not a record of its own.
import type { ComponentChildren } from "preact";
import { useEffect, useState } from "preact/hooks";
import type { Agent, RuntimeStatus, UUID } from "../protocol/generated";
import { Failure } from "../protocol/generated";
import { Capability } from "../protocol/capabilities.generated";
import type { Store } from "../model/store";
import { CallFailed } from "../wire/link";
import { describe } from "../model/errors";
import { planInForce } from "../model/currentPlan";
import { folderPath, groupOf } from "../model/groups";
import { machineRuntimeLine, offersMachineSignIn, signInOnTheMac } from "../model/runtimes";
import {
  canStart, firstBuild, firstBuildStarter, firstBuildTasks, githubTask, isArchived, isFirstBuild, kindName, neitherLine,
  runtimeTask, starterLine, starters, taskStates, type PlanFacts, type PlanTask, type Starter, type TaskState,
} from "../model/firstBuild";
import { go } from "../route";
import { Chat } from "./Chat";
import { ConnectDialog } from "./ConnectorSetup";
import { RuntimeSignInDialog } from "./RuntimeSignInDialog";

/** The machine the session runs on: the one it was started on, else this Mac's host, else the first that answers. */
export function firstBuildHost(store: Store): string | undefined {
  const hosts = store.hosts.value;
  const kept = firstBuild.session.value?.host;
  if (kept && hosts.some((h) => h.id === kept)) return kept;
  const mac = store.macHostID.value;
  if (hosts.some((h) => h.id === mac)) return mac;
  return (hosts.find((h) => store.hostIsOnline(h.id)) ?? hosts[0])?.id;
}

/** The first-build session on that machine: the one kept, or one labelled first-build (a second client's Submit). */
function firstBuildAgent(store: Store, host: string): Agent | undefined {
  const kept = firstBuild.session.value;
  if (kept?.host === host) {
    const agent = store.agent(host, kept.id);
    // The kept one by its id: a record heard before its labels is still it, until it is archived.
    if (agent) return isArchived(agent) ? undefined : agent;
  }
  return (store.agents.value[host] ?? []).find(isFirstBuild);
}

/** Claude unless the person picks another; the first listed when there is no Claude. */
function chosenRuntime(runtimes: readonly RuntimeStatus[], id: string): RuntimeStatus | undefined {
  return runtimes.find((r) => r.runtime.id === id) ?? runtimes[0];
}

function runtimeReady(status: RuntimeStatus | undefined): boolean {
  return !!status && "available" in status.availability && !status.setBy;
}

function offersInstall(status: RuntimeStatus): boolean {
  return status.runtime.install != null && ("missing" in status.availability || "installFailed" in status.availability);
}

export function PlanPage({ store, down }: { store: Store; down: boolean }) {
  const idea = firstBuild.sent.value ?? "";
  const starter = firstBuild.starter.value;
  const host = firstBuildHost(store);
  const agent = host ? firstBuildAgent(store, host) : undefined;
  const runtimes = host ? store.runtimes.value[host] : undefined;
  const [runtimeID, setRuntimeID] = useState("claude");
  const runtime = chosenRuntime(runtimes ?? [], runtimeID);
  const [github, setGitHub] = useState(false);
  const [starting, setStarting] = useState(false);
  const [problem, setProblem] = useState<string>();
  const [signingIn, setSigningIn] = useState<RuntimeStatus>();
  const [connecting, setConnecting] = useState(false);
  const plan = agent ? planInForce(agent) : null;
  const facts: PlanFacts = {
    runtimeReady: runtimeReady(runtime),
    githubConnected: github,
    plan: plan?.entries,
    waitsForPerson: agent ? groupOf(agent) === "needsAttention" : false,
  };
  const ready = canStart(facts);

  // A session found that this browser did not start (a second client's Submit) is kept as the page's.
  useEffect(() => {
    if (host && agent && firstBuild.session.peek()?.id !== agent.id) firstBuild.started({ host, id: agent.id });
  }, [host, agent?.id]);

  // The session is the page's open one, as a chat opened from the sidebar: its transcript, and its
  // plan, which a host sends only to a page that shows the session (#203).
  useEffect(() => {
    if (host && agent) void store.openSession(host, agent.id);
  }, [host, agent?.id]);

  // The session archived: the plan page goes (section 5). Only a session listed as archived: a
  // list that does not have it yet, or a record heard before its labels, is no answer.
  const kept = firstBuild.session.value;
  const keptAgent = kept ? store.agent(kept.host, kept.id) : undefined;
  useEffect(() => {
    if (keptAgent && isArchived(keptAgent)) firstBuild.leave();
  }, [keptAgent?.state, keptAgent?.archivedAt]);

  // The GitHub task is ticked from the connector: from this page's dialog, or another client.
  // Read again every few seconds until it is connected.
  useEffect(() => {
    if (!host || github) return;
    let live = true;
    const read = async () => {
      const connected = await store.githubConnected(host);
      if (live && connected) setGitHub(true);
    };
    void read();
    const timer = setInterval(() => void read(), 5_000);
    return () => { live = false; clearInterval(timer); };
  }, [host, github]);

  // A runtime installing or signed in elsewhere: read the list again while it is not ready.
  useEffect(() => {
    if (!host || facts.runtimeReady) return;
    if (!runtimes) void store.reloadRuntimeList(host);
    const timer = setInterval(() => void store.reloadRuntimeList(host), 3_000);
    return () => clearInterval(timer);
  }, [host, facts.runtimeReady]);

  // The agent starts once the page's tasks are done and a starter is chosen (section 7).
  const start = async () => {
    if (!host || !starter || !runtime || agent || starting) return;
    setStarting(true);
    try {
      const id: UUID = await store.link.call("firstBuild/start", { idea, starter, runtimeID: runtime.runtime.id }, host);
      firstBuild.started({ host, id });
    } catch (e) {
      // A first build there already is the session the page shows.
      const there = e instanceof CallFailed && e.code === Failure.firstBuildRunning
        ? (e.data as { agentID?: string } | undefined)?.agentID : undefined;
      if (there) firstBuild.started({ host, id: there });
      else setProblem(e instanceof CallFailed ? e.message : `${describe(e)}, so the agent did not start.`);
    } finally {
      setStarting(false);
    }
  };
  useEffect(() => {
    if (ready && starter && !agent && !problem && host && store.has(host, Capability.firstBuild1)) void start();
  }, [ready, starter, runtime?.runtime.id, agent?.id, problem, host]);

  const openAgents = () => {
    firstBuild.leave();
    if (host && agent) go({ host, folder: folderPath(agent), session: agent.id });
    else go({});
  };

  const control = (task: PlanTask) => {
    if (task.words === runtimeTask && !facts.runtimeReady) {
      return host && <RuntimeControl store={store} host={host} runtimes={runtimes} runtime={runtime}
        choose={setRuntimeID} signIn={setSigningIn} />;
    }
    if (task.words === githubTask && !facts.githubConnected) {
      return <button type="button" onClick={() => setConnecting(true)}>Connect GitHub…</button>;
    }
    return null;
  };

  return (
    <main class="first-build-plan">
      <button type="button" class="first-build-open" title="The usual page, with this session open" onClick={openAgents}>
        Open Agents
      </button>
      <section class="first-build-plan-head" aria-label="What will be built">
        <h1>{idea}</h1>
        {starter ? (
          <p class="first-build-starter">
            <span class="quiet">{starterLine(starter)}</span>
            {!agent && (
              <button type="button" title="Build the idea on the other starter"
                onClick={() => firstBuild.choose(starters.find((s) => s !== starter)!)}>Change</button>
            )}
          </p>
        ) : <ChooseStarter idea={idea} />}
        {starter && (
          <>
            <ol class="first-build-tasks" aria-label="Tasks">
              {firstBuildTasks(starter).map((task, i) => (
                <TaskRow key={task.words} task={task} state={taskStates(starter, facts)[i]!}>{control(task)}</TaskRow>
              ))}
            </ol>
            {!agent && (
              <StartLine problem={problem} starting={starting || ready}
                retry={() => setProblem(undefined)} />
            )}
          </>
        )}
      </section>
      <div class="first-build-chat">
        {host && agent ? <Chat store={store} host={host} session={agent.id} down={down} />
          : <p class="quiet small first-build-chat-empty">The agent's chat shows here when it starts.</p>}
      </div>
      {signingIn && host && (
        <RuntimeSignInDialog store={store} host={host} runtimeID={signingIn.runtime.id} runtimeName={signingIn.runtime.name}
          machine={store.hosts.value.find((h) => h.id === host)?.name ?? host}
          close={() => { setSigningIn(undefined); void store.reloadRuntimeList(host); }} />
      )}
      {connecting && host && (
        <ConnectDialog store={store} host={host} provider="github"
          connected={() => setGitHub(true)} close={() => setConnecting(false)} />
      )}
    </main>
  );
}

/** Words that named no starter, or one neither starter makes (sections 3 and 4). */
function ChooseStarter({ idea }: { idea: string }) {
  const neither = firstBuildStarter(idea) === "neither";
  return (
    <div class="first-build-choose">
      <p class="quiet">{neither ? neitherLine : "What kind of app is it?"}</p>
      <p class="row-actions">
        {starters.map((s: Starter) => (
          <button type="button" key={s} onClick={() => firstBuild.choose(s)}>{kindName(s)}</button>
        ))}
        {neither && <button type="button" title="Change your idea" onClick={() => firstBuild.back()}>Back</button>}
      </p>
    </div>
  );
}

const stateWords: Record<TaskState, string> = {
  "to-do": "To do", doing: "Doing", done: "Done", "waits-for-you": "Waits for you",
};

/** One task and its state: to do, doing (a spinner), done (a tick), or waits for you (the attention tint). */
function TaskRow({ task, state, children }: { task: PlanTask; state: TaskState; children?: ComponentChildren }) {
  return (
    <li class={`first-build-task ${state}`}>
      <span class="first-build-task-icon" aria-hidden="true">
        {state === "doing" ? <span class="spinner" /> : state === "done" ? "✓" : state === "waits-for-you" ? "!" : ""}
      </span>
      <div class="first-build-task-body">
        <p>
          <span class="first-build-task-words">{task.words}</span>
          <span class="visually-hidden">: {stateWords[state]}</span>
          {state === "waits-for-you" && <span class="first-build-waits" aria-hidden="true">Waits for you</span>}
        </p>
        {state !== "done" && children}
      </div>
    </li>
  );
}

/** Claude by default, with the other runtimes in a list beside it; installed and signed in on the session's machine. */
function RuntimeControl({ store, host, runtimes, runtime, choose, signIn }: {
  store: Store; host: string; runtimes: readonly RuntimeStatus[] | undefined; runtime: RuntimeStatus | undefined;
  choose: (id: string) => void; signIn: (status: RuntimeStatus) => void;
}) {
  if (!runtimes || !runtime) {
    return <p class="quiet small"><span class="spinner" aria-hidden="true" /> Looking for agent runtimes on this machine…</p>;
  }
  const a = runtime.availability;
  const signs = offersMachineSignIn(runtime) && store.has(host, Capability.runtimesSignIn1);
  return (
    <div class="first-build-runtime">
      <span class="strong">{runtime.runtime.name}</span>
      <span class="quiet small">{machineRuntimeLine(runtime)}</span>
      {signs && <button type="button" onClick={() => signIn(runtime)}>Sign In…</button>}
      {"installing" in a ? <span class="spinner" aria-label="Installing" />
        : offersInstall(runtime) && (
          <button type="button" onClick={() => void store.updateRuntime(host, runtime.runtime.id)}>Install</button>
        )}
      {runtimes.length > 1 && (
        <select aria-label="Other runtime" value={runtime.runtime.id} onChange={(e) => choose(e.currentTarget.value)}>
          {runtimes.map((r) => <option key={r.runtime.id} value={r.runtime.id}>{r.runtime.name}</option>)}
        </select>
      )}
      {"needsSignIn" in a && !signs && store.isMac(host) && <p class="quiet small">{signInOnTheMac}</p>}
    </div>
  );
}

/** Under the list: why the agent has not started yet, that it is starting, or why it did not. */
function StartLine({ problem, starting, retry }: { problem: string | undefined; starting: boolean; retry: () => void }) {
  if (problem) {
    return (
      <p class="first-build-start problem" role="alert">
        <span>{problem}</span>
        <button type="button" onClick={retry}>Try Again</button>
      </p>
    );
  }
  return (
    <p class="first-build-start quiet small" role="status">
      {starting ? <><span class="spinner" aria-hidden="true" /> Starting the agent…</>
        : "The agent starts when the first two tasks are done."}
    </p>
  );
}
