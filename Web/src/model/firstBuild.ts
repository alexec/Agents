// The first build (#5048, spec 5048-first-build): the question page a newcomer's first open
// shows, "Let's build your idea." The ideas its box rotates through, who sees it (section 9),
// and what this browser keeps: whether the page shows, and the idea once it was sent. Kept in
// localStorage, as the achievements' cards are; the Mac window keeps the same in its defaults.
import { signal } from "@preact/signals";

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

const keptKey = "agents.firstBuild.page";
const ideaKey = "agents.firstBuild.idea";

/** This browser's half: whether the page shows, and the idea it sent. */
export class FirstBuildStore {
  readonly kept = signal<Kept | null>(null);
  readonly sent = signal<string | null>(null);

  constructor(private readonly storage: Storage | undefined) {
    const kept = storage?.getItem(keptKey);
    if (kept === "showing" || kept === "gone") this.kept.value = kept;
    const sent = storage?.getItem(ideaKey);
    if (sent) this.sent.value = sent;
  }

  /** What the page knows now; a change is kept at once. */
  take(facts: FirstBuildFacts): void {
    const kept = weigh(this.kept.peek(), facts, this.sent.peek() !== null);
    if (kept === this.kept.peek()) return;
    this.kept.value = kept;
    if (kept) this.write(keptKey, kept);
  }

  /** Submit: the words, kept for the plan page (#5054). */
  send(idea: string): void {
    const words = idea.trim();
    if (!words) return;
    this.sent.value = words;
    this.write(ideaKey, words);
  }

  private write(key: string, value: string): void {
    try {
      this.storage?.setItem(key, value);
    } catch {
      // Storage full or off: this look still holds it.
    }
  }
}

// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
export const firstBuild = new FirstBuildStore(globalThis.window?.localStorage);
