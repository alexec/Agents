// The question page (#5051, spec 5048-first-build section 1): a newcomer's first open on the
// web page, as the Mac window's. The Huddle, "Let's build your idea.", and one prompt box whose
// placeholder rotates through ideas. No sidebar, no toolbar, no way past it. New App… (#5132) opens it
// again for a person who is set up, with Cancel.
import { useEffect, useRef, useState } from "preact/hooks";
import { firstBuild, firstBuildIdeas, ideaInterval, nextIdea, type FirstBuildFacts } from "../model/firstBuild";
import type { Store } from "../model/store";
import { Huddle } from "./Huddle";

/** What the store knows, for `weigh`: only from machines that answered themselves, not a copy. */
export function firstBuildFacts(store: Store): FirstBuildFacts {
  const hosts = store.hosts.value.map((h) => h.id);
  const folders = store.folders.value, agents = store.agents.value, achievements = store.achievements.value;
  const fromDevice = store.fromDevice.value;
  return {
    loaded: hosts.every((h) => folders[h] !== undefined && agents[h] !== undefined && achievements[h] !== undefined
      && !fromDevice.has(h)),
    hasMachine: hosts.length > 0,
    hasFolder: hosts.some((h) => (folders[h]?.length ?? 0) > 0),
    hasAgent: hosts.some((h) => (agents[h]?.length ?? 0) > 0),
    ranAgent: hosts.some((h) => achievements[h]?.earned.some((e) => e.id === "firstAgent") ?? false),
  };
}

/** Whether the page shows now: weighed from the store each time it changes. */
export function showsFirstBuild(store: Store): boolean {
  firstBuild.take(firstBuildFacts(store));
  return firstBuild.kept.value === "showing";
}

function reducedMotion(): boolean {
  return typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
}

export function QuestionPage() {
  const sent = firstBuild.sent.value;
  const another = firstBuild.another.value;
  // Back from the plan page: the words are still in the box (section 4).
  const [words, setWords] = useState(sent ?? firstBuild.draft.peek());
  const [focused, setFocused] = useState(false);
  const [shown, setShown] = useState(0);
  const [still] = useState(reducedMotion);
  const box = useRef<HTMLTextAreaElement>(null);
  const empty = words.trim() === "";

  useEffect(() => { box.current?.focus(); }, []);

  // One idea every 4 s while the box is empty; it stops on the one it shows when the person types.
  useEffect(() => {
    if (words !== "" || sent) return;
    const timer = window.setInterval(() => setShown(nextIdea), ideaInterval);
    return () => window.clearInterval(timer);
  }, [words === "", sent]);

  const submit = () => {
    if (empty || sent) return;
    firstBuild.send(words);
  };

  const keyDown = (e: KeyboardEvent) => {
    if (e.isComposing) return;
    if (e.key === "Escape" && another) {
      // Escape is Cancel, as in a dialog.
      e.preventDefault();
      firstBuild.leave();
      return;
    }
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      submit();
    } else if (e.key === "Tab" && !e.shiftKey && words === "" && !sent) {
      // Tab takes the idea that shows, to change it.
      e.preventDefault();
      setWords(firstBuildIdeas[shown]!.words);
    }
  };

  return (
    <main class="first-build">
      <div class="first-build-page">
        <Huddle focused={focused} typed={words.length} height={112} />
        <h1>Let's build your idea.</h1>
        <form class="first-build-box" onSubmit={(e) => { e.preventDefault(); submit(); }}>
          <div class="first-build-field">
            <textarea ref={box} rows={4} value={words} aria-label="Your idea" readOnly={sent !== null}
              aria-describedby={words === "" ? "first-build-idea" : undefined}
              onInput={(e) => setWords(e.currentTarget.value)} onKeyDown={keyDown}
              onFocus={() => setFocused(true)} onBlur={() => setFocused(false)} />
            {words === "" && (
              <div class="first-build-ideas" aria-hidden="true">
                {firstBuildIdeas.map((idea, i) => (
                  <span key={idea.words} class={`first-build-idea${i === shown ? " shown" : ""}${still ? " still" : ""}`}
                    id={i === shown ? "first-build-idea" : undefined}>{idea.words}</span>
                ))}
              </div>
            )}
          </div>
          <div class="first-build-foot">
            <span class="quiet small" role="status">
              {sent ? "Making your plan…" : ""}
            </span>
            {/* Only after New App… (#5132): a newcomer's first open has no way past it. */}
            {another && <button type="button" onClick={() => firstBuild.leave()}>Cancel</button>}
            <button type="submit" class="prominent" disabled={empty || sent !== null}>Submit</button>
          </div>
        </form>
      </div>
    </main>
  );
}
