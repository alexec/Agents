// A machine page's Agent Loops sections (#5273, spec 5239 board 6), as the window's and the Remote's MachineAgentsSections:
// the version the machine runs, since when, and the changes since the version before, newest first, with Show all; the
// person's other machines, each with how far it is behind this one, which opens those changes; and the versions this
// machine ran. Read from the control plane with machines/agents when the page opens, so it says when (#5139).
import { useEffect, useState } from "preact/hooks";
import type { Store } from "../model/store";
import type { AgentsChange, AgentsChanges, MachineAgents as Agents, MachineAgentsOther, MachineRef } from "../protocol/generated";
import {
  agentsTitle, behindLine, changeLabel, changesShown, changeLink, compareWith, dayWords, isBehind, listHeading, noVersion, otherLine,
  shortVersion, showAllWords, sinceLine, versionParts, whenWords,
} from "../model/agentsVersions";
import { LastUpdate } from "./LastUpdate";

export function MachineAgents({ store, host }: { store: Store; host: string }) {
  const [agents, setAgents] = useState<Agents | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [readAt, setReadAt] = useState<number | null>(null);
  const [all, setAll] = useState<AgentsChanges | null>(null);
  const [opened, setOpened] = useState<Record<string, AgentsChanges>>({});
  const [asking, setAsking] = useState<string | null>(null);
  useEffect(() => {
    let gone = false;
    setAgents(null); setFailure(null); setReadAt(null); setAll(null); setOpened({});
    store.link.call("machines/agents", { host: host as MachineRef }).then(
      (a) => { if (!gone) { setAgents(a); setReadAt(Date.now()); } },
      () => { if (!gone) setFailure("The control plane can’t say which version runs here now."); });
    return () => { gone = true; };
  }, [store, host]);

  const showAll = (a: Agents) => {
    if (a.previous === undefined) return;
    setAsking("all");
    store.link.call("machines/agentsChanges", { base: a.previous, head: a.version }).then(
      (c) => { setAll(c); setAsking(null); }, () => setAsking(null));
  };
  // Opens or closes another machine's changes: the newest few, then every one with Show all.
  const open = (other: MachineAgentsOther, a: Agents, all = false) => {
    if (!all && opened[other.host]) {
      const { [other.host]: _, ...rest } = opened;
      setOpened(rest);
      return;
    }
    setAsking(other.host);
    store.link.call("machines/agentsChanges", compareWith(other, a.version, all ? undefined : changesShown)).then(
      (c) => { setOpened((o) => ({ ...o, [other.host]: c })); setAsking(null); }, () => setAsking(null));
  };

  const shown = all ?? agents?.changes;
  const parts = agents ? versionParts(agents.version) : null;
  return (
    <>
      <section class="machine-agents" aria-labelledby="machine-agents">
        <h3 class="section-head" id="machine-agents" title="The version of Agent Loops this machine runs">{agentsTitle}</h3>
        {!agents ? <p class="hint">{failure ?? "Loading…"}</p> : agents.version === "" ? <p class="hint">{noVersion}</p> : (
          <>
            <p class="agents-version"><span class="strong">{parts!.name}</span>{parts!.build && <span class="quiet"> {parts!.build}</span>}</p>
            {sinceLine(agents) && <p class="quiet small">{sinceLine(agents)}</p>}
          </>
        )}
        {readAt !== null && <p class="quiet small"><LastUpdate at={readAt} /></p>}
      </section>
      {agents && shown && shown.changes.length > 0 && (
        <section aria-labelledby="machine-agents-changes">
          <h3 class="section-head" id="machine-agents-changes">{listHeading(shown)}</h3>
          <ul class="agents-changes">{shown.changes.map((c) => <ChangeRow key={c.sha} change={c} />)}</ul>
          {showAllWords(shown) && (
            <p><button type="button" class="link small" disabled={asking === "all"} onClick={() => showAll(agents)}>{showAllWords(shown)}</button></p>
          )}
        </section>
      )}
      {agents && agents.others.length > 0 && (
        <section aria-labelledby="machine-agents-others">
          <h3 class="section-head" id="machine-agents-others">Other machines</h3>
          <ul class="agents-others">
            {agents.others.map((other) => {
              const behind = behindLine(other);
              const compare = opened[other.host];
              return (
                <li key={other.host}>
                  <p><span class="strong">{other.name}</span></p>
                  <p class="quiet small">{otherLine(other)}</p>
                  {behind && (
                    <p><button type="button" class={`link small${isBehind(other) ? " warning" : ""}`} aria-expanded={compare !== undefined}
                      disabled={asking === other.host} onClick={() => open(other, agents)}>{behind}</button></p>
                  )}
                  {compare && (
                    <>
                      <ul class="agents-changes">{compare.changes.map((c) => <ChangeRow key={c.sha} change={c} />)}</ul>
                      {showAllWords(compare) && (
                        <p><button type="button" class="link small" disabled={asking === other.host}
                          onClick={() => open(other, agents, true)}>{showAllWords(compare)}</button></p>
                      )}
                    </>
                  )}
                </li>
              );
            })}
          </ul>
        </section>
      )}
      {agents && agents.history.length > 1 && (
        <section aria-labelledby="machine-agents-history">
          <h3 class="section-head" id="machine-agents-history">History</h3>
          {agents.history.map((past, i) => (
            <div class="setting" key={`${past.version}-${i}`}>
              <span>{shortVersion(past.version)}</span>
              {past.since !== undefined && <span class="quiet">{whenWords(past.since)}</span>}
            </div>
          ))}
        </section>
      )}
    </>
  );
}

/** One change: its PR's number, which opens it on GitHub, its title and its day. */
function ChangeRow({ change }: { change: AgentsChange }) {
  return (
    <li class="agents-change">
      <a href={changeLink(change)} target="_blank" rel="noopener noreferrer">{changeLabel(change)}</a>
      <span class="agents-change-title">{change.title}</span>
      {change.date !== undefined && <span class="quiet small">{dayWords(change.date)}</span>}
    </li>
  );
}
