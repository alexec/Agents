// The first build (#5048, spec 5048-first-build): the question page a newcomer's first open
// shows, "Let's build your idea." The ideas its box rotates through, who sees it (section 9),
// and what this browser keeps: whether the page shows, and the idea once it was sent. Kept in
// localStorage, as the achievements' cards are; the Mac window keeps the same in its defaults.
import { signal } from "@preact/signals";
import type { Agent, PlanEntry } from "../protocol/generated";

export type Starter = "iphone-app" | "web-service";

/** The ideas, in order, each with its starter (section 2); held to Fixtures/web/first-build/ideas.json. */
export const firstBuildIdeas: readonly { words: string; starter: Starter }[] = [
  { words: "An iPhone app that shows the weather where I am", starter: "iphone-app" },
  { words: "A web page that shows this week's weather for my town", starter: "web-service" },
  { words: "An iPhone app that reminds me to water my plants", starter: "iphone-app" },
  { words: "A website for my book club's reading list", starter: "web-service" },
  { words: "An iPhone app that logs my runs", starter: "iphone-app" },
  { words: "A web service that emails me a daily summary of my GitHub", starter: "web-service" },
];

/** How long each idea shows in the box, in milliseconds. */
export const ideaInterval = 4000;

/** The idea after `index`, round the list. */
export function nextIdea(index: number): number {
  return (index + 1) % firstBuildIdeas.length;
}

/** What the page knows of the control plane, from every machine's own answer. */
export interface FirstBuildFacts {
  /** Every machine has answered with its folders, its sessions and its achievements. */
  loaded: boolean;
  hasMachine: boolean;
  hasFolder: boolean;
  hasAgent: boolean;
  /** The host's achievement "First agent started": an agent ran once, archived or not. */
  ranAgent: boolean;
}

/** As `GetStarted.Facts.isSetUp`: a person who has a folder or ever ran an agent is not new. */
export function isSetUp(facts: FirstBuildFacts): boolean {
  return facts.hasFolder || facts.hasAgent || facts.ranAgent;
}

export type Kept = "showing" | "gone";

/**
 * Whether the question page shows, as `GetStarted.card(kept:facts:)`: weighed once every
 * machine has answered, so a person set up already is never taken for a newcomer by a list
 * that has not come in. With no machine yet (hosted, in a browser), not until one is there: an
 * agent needs one. Once showing, it stays until the person is set up some other way; once
 * an idea is sent, it stays for the plan page (#5054), which the first-build session sets up.
 */
export function weigh(kept: Kept | null, facts: FirstBuildFacts, sent: boolean): Kept | null {
  if (kept === "gone") return "gone";
  if (!facts.loaded || !facts.hasMachine) return kept;
  if (kept === null) return isSetUp(facts) ? "gone" : "showing";
  return isSetUp(facts) && !sent ? "gone" : "showing";
}

// MARK: The plan page (#5054, spec sections 3 to 6), as FirstBuild in AgentsKitCore (#5053).

/** What the words of an idea say about its starter (sections 3 and 4). */
export type StarterPick = Starter | "unknown" | "neither";

const iphoneWords = new Set(["iphone", "ios", "ipad", "testflight"]);
const webWords = new Set(["web", "website", "site", "page", "service", "server", "api", "email"]);
const neitherWords = new Set(["mac", "macos", "android", "game", "windows", "desktop"]);

/**
 * The starter an idea picks: an idea from the list keeps its own; typed words pick by the first
 * word that names a kind (`app store` names the iPhone app). A bare "app" picks nothing.
 * `FirstBuild.starter(for:)`, held to Fixtures/web/first-build/starters.json.
 */
export function firstBuildStarter(idea: string): StarterPick {
  const trimmed = idea.trim();
  const listed = firstBuildIdeas.find((i) => i.words.toLowerCase() === trimmed.toLowerCase());
  if (listed) return listed.starter;
  const words = trimmed.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter((w) => w !== "");
  for (let index = 0; index < words.length; index++) {
    const word = words[index]!;
    if (iphoneWords.has(word)) return "iphone-app";
    if (word === "app" && words[index + 1] === "store") return "iphone-app";
    if (webWords.has(word)) return "web-service";
    if (neitherWords.has(word)) return "neither";
  }
  return "unknown";
}

/** The line above the choice for an idea neither starter makes (section 4). */
export const neitherLine =
  "Agent Loops can start with an iPhone app or a web service. Choose one, and the agent builds your idea on it as far as it goes.";

export const starters: readonly Starter[] = ["iphone-app", "web-service"];

/** Who does a task: the page, before the agent can start, or the agent. */
export type Doer = "app" | "agent";

/** One task of a starter's list, in the skill's exact words (section 6). */
export interface PlanTask { words: string; doer: Doer }

/** The page's two tasks, first on both lists. */
export const runtimeTask = "Set up the agent runtime";
export const githubTask = "Connect GitHub";

/** A starter's task list, in order; the skill writes the same words as its plan (#5052). Held to first-build/tasks.json. */
export function firstBuildTasks(starter: Starter): PlanTask[] {
  const app: PlanTask[] = [{ words: runtimeTask, doer: "app" }, { words: githubTask, doer: "app" }];
  const agent = (words: string): PlanTask => ({ words, doer: "agent" });
  return starter === "iphone-app"
    ? [...app, agent("Make the repository from agentloops-dev/iphone-app-starter"), agent("Join the Apple Developer Program"),
      agent("Put the App Store Connect key in the repository's CI"), agent("Set up Sentry"),
      agent("Send the first build to TestFlight"), agent("Approve the first build")]
    : [...app, agent("Make the repository from agentloops-dev/web-service-starter"), agent("Set up Google Cloud (Cloud Run)"),
      agent("Set up Sentry"), agent("Deploy the first version"), agent("Approve the first deploy")];
}

/** The line under the title: what will be built, and from which template. */
export function starterLine(starter: Starter): string {
  return starter === "iphone-app" ? "An iPhone app, from agentloops-dev/iphone-app-starter" : "A web service, from agentloops-dev/web-service-starter";
}

/** The choice's own words. */
export function kindName(starter: Starter): string {
  return starter === "iphone-app" ? "iPhone app" : "Web service";
}

export type TaskState = "to-do" | "doing" | "done" | "waits-for-you";

/** What the plan page knows (section 6): its two tasks from real state, the agent's from its plan. */
export interface PlanFacts {
  runtimeReady: boolean;
  githubConnected: boolean;
  /** The first-build session's plan in force, once it has sent one. */
  plan?: readonly PlanEntry[] | undefined;
  /** The session waits on the person (a card, a question). */
  waitsForPerson: boolean;
}

function normalised(words: string): string {
  return words.trim().replace(/^\.+|\.+$/g, "").trim().toLowerCase().replaceAll("\u2019", "'");
}

/**
 * Each task with its state: the agent's are to do until its plan comes, and one the plan does
 * not name stays to do. The task in progress waits for you while the session waits on the person.
 */
export function taskStates(starter: Starter, facts: PlanFacts): TaskState[] {
  return firstBuildTasks(starter).map((task) => {
    if (task.words === runtimeTask) return facts.runtimeReady ? "done" : "to-do";
    if (task.words === githubTask) return facts.githubConnected ? "done" : "to-do";
    const entry = facts.plan?.find((e) => normalised(e.content) === normalised(task.words));
    if (entry?.status === "completed") return "done";
    if (entry?.status === "in_progress") return facts.waitsForPerson ? "waits-for-you" : "doing";
    return "to-do";
  });
}

/** The page's tasks are done, so the agent can start. */
export function canStart(facts: PlanFacts): boolean {
  return facts.runtimeReady && facts.githubConnected;
}

/** The label firstBuild/start gives the session, by which the page finds it. */
export const firstBuildLabel = "first-build";

/** The session is archived: the plan page goes (section 5). */
export function isArchived(agent: Pick<Agent, "state" | "archivedAt">): boolean {
  return agent.state === "archived" || agent.archivedAt != null;
}

/** The first-build session: labelled first-build, and not archived. */
export function isFirstBuild(agent: Pick<Agent, "state" | "archivedAt" | "labels">): boolean {
  return !isArchived(agent) && (agent.labels ?? []).some((l) => l.value === firstBuildLabel);
}

const keptKey = "agents.firstBuild.page";
const ideaKey = "agents.firstBuild.idea";
const starterKey = "agents.firstBuild.starter";
const sessionKey = "agents.firstBuild.session";
const anotherKey = "agents.firstBuild.another";

/** The menu item that opens the question page again for a person who is set up (#5132), as the window's. */
export const newAppItem = "New App…";

/** The first-build session this browser started or found: the machine it runs on, and its id. */
export interface FirstBuildSession { host: string; id: string }

/**
 * This browser's half: whether the page shows, the idea it sent, the starter it shows and the
 * session it started. The session itself is the record (section 5); this keeps only where the
 * page is, and the idea until the agent has it.
 */
export class FirstBuildStore {
  readonly kept = signal<Kept | null>(null);
  /** The idea sent: the plan page shows while it is set. */
  readonly sent = signal<string | null>(null);
  /** The starter the plan page shows: picked from the words, or chosen there. */
  readonly starter = signal<Starter | null>(null);
  readonly session = signal<FirstBuildSession | null>(null);
  /** The words Back takes to the question page's box (section 4); not kept. */
  readonly draft = signal("");
  /** New App… opened the pages (#5132): the question page has Cancel, and Submit starts one more first build. */
  readonly another = signal(false);

  constructor(private readonly storage: Storage | undefined) {
    const kept = storage?.getItem(keptKey);
    if (kept === "showing" || kept === "gone") this.kept.value = kept;
    const sent = storage?.getItem(ideaKey);
    if (sent) this.sent.value = sent;
    const starter = storage?.getItem(starterKey);
    if (starter === "iphone-app" || starter === "web-service") this.starter.value = starter;
    try {
      const session = JSON.parse(storage?.getItem(sessionKey) ?? "null") as FirstBuildSession | null;
      if (session && typeof session.host === "string" && typeof session.id === "string") this.session.value = session;
    } catch { /* none kept */ }
    this.another.value = storage?.getItem(anotherKey) === "true";
  }

  /** What the page knows now; a change is kept at once. */
  take(facts: FirstBuildFacts): void {
    // New App… opened the page on purpose: a person who is set up is meant to see it.
    if (this.another.peek()) return;
    const kept = weigh(this.kept.peek(), facts, this.sent.peek() !== null);
    if (kept === this.kept.peek()) return;
    this.kept.value = kept;
    if (kept) this.write(keptKey, kept);
  }

  /** Submit: the words, kept for the plan page, with the starter they pick (section 3). */
  send(idea: string): void {
    const words = idea.trim();
    if (!words) return;
    this.sent.value = words;
    this.write(ideaKey, words);
    const pick = firstBuildStarter(words);
    this.choose(pick === "unknown" || pick === "neither" ? null : pick);
  }

  /** The plan page's Change, or its choice for words that named no starter. */
  choose(starter: Starter | null): void {
    this.starter.value = starter;
    this.write(starterKey, starter);
  }

  /** The session firstBuild/start answered with, or the one there already. */
  started(session: FirstBuildSession): void {
    this.session.value = session;
    this.write(sessionKey, JSON.stringify(session));
  }

  /** Back, for an idea neither starter fits (section 4): the question page, the words still in the box. */
  back(): void {
    this.draft.value = this.sent.peek() ?? "";
    this.sent.value = null;
    this.write(ideaKey, null);
    this.choose(null);
  }

  /** New App… (#5132): the question page again, with an empty box and Cancel. */
  newApp(): void {
    this.leave();
    this.draft.value = "";
    this.another.value = true;
    this.write(anotherKey, "true");
    this.kept.value = "showing";
    this.write(keptKey, "showing");
  }

  /**
   * Open Agents, the session archived (section 5), or Cancel after New App…: the usual page, and
   * the plan page does not come back.
   */
  leave(): void {
    this.kept.value = "gone";
    this.write(keptKey, "gone");
    this.sent.value = null;
    this.starter.value = null;
    this.session.value = null;
    this.another.value = false;
    for (const key of [ideaKey, starterKey, sessionKey, anotherKey]) this.write(key, null);
  }

  private write(key: string, value: string | null): void {
    try {
      if (value === null) this.storage?.removeItem(key);
      else this.storage?.setItem(key, value);
    } catch {
      // Storage full or off: this look still holds it.
    }
  }
}

// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
export const firstBuild = new FirstBuildStore(globalThis.window?.localStorage);
