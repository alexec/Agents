// What was exchanged with the agent (ArtifactsPane, DocumentView, #258): a file attached
// to a prompt, or one handed back by name. Derived from the conversation that is read,
// newest first. A file inside the agent's folders opens in Files, as it is now. Anything
// else is read here: its own text, a link, or a sentence saying where it is.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import {
  artifactsIn, bytesInWords, destinationOf, insideScope, missingInListing, type Artifact,
} from "../model/artifacts";
import { absolutePath } from "../model/fileWatch";
import { focusedEntry } from "../model/focus";
import { fromWireDate } from "../protocol/dates";
import { Markdown } from "../render/markdown";
import { isMenuKey, openContextMenu } from "./ContextMenu";
import { pathOf, setPane } from "./files/paneState";
import { ago } from "./SessionRow";

export function Exchanged({ store, host, session }: { store: Store; host: string; session: string }) {
  const agent = store.agent(host, session);
  const roots = agent
    ? [absolutePath(agent.cwd), ...(agent.additionalDirectories ?? []).map(absolutePath)]
    : [];
  const artifacts = artifactsIn(store.entries.value);
  const opened = useSignal<string | null>(null);
  const missing = useSignal<ReadonlySet<string>>(new Set());
  const ids = artifacts.map((artifact) => artifact.id).join("\n");
  const rootKey = roots.join("\n");
  useEffect(() => {
    let current = true;
    const files = artifacts.filter((artifact) => {
      const destination = destinationOf(artifact);
      return destination.kind === "file" && insideScope(destination.path, roots);
    });
    const folders = new Map<string, { artifact: Artifact; name: string }[]>();
    for (const artifact of files) {
      const destination = destinationOf(artifact);
      if (destination.kind !== "file") continue;
      const folder = destination.path.slice(0, destination.path.lastIndexOf("/")) || "/";
      const name = destination.path.slice(folder === "/" ? 1 : folder.length + 1);
      const list = folders.get(folder) ?? [];
      list.push({ artifact, name });
      folders.set(folder, list);
    }
    void Promise.all([...folders].map(async ([folder, rows]) => {
      try {
        const listing = await store.listFiles(host, session, folder);
        return rows.filter((row) => missingInListing(listing, row.name)).map((row) => row.artifact.id);
      } catch (error) {
        // A folder that is gone takes its files with it. Any other refusal says nothing
        // about whether the file is still there.
        return /is gone/.test(describe(error)) ? rows.map((row) => row.artifact.id) : [];
      }
    })).then((groups) => {
      if (current) missing.value = new Set(groups.flat());
    }, () => {});
    return () => { current = false; };
  }, [host, session, ids, rootKey]);

  const shown = artifacts.find((artifact) => artifact.id === opened.value);
  // A file inside the agent's folders never sets `opened`: it opens under Files. Anything
  // else, including a file that lives somewhere else on the Mac, is read here.
  if (shown) return <Reading artifact={shown} back={() => { opened.value = null; }} />;
  const root = agent ? pathOf(agent.cwd) : null;
  return (
    <div class="exchanged">
      {artifacts.length === 0 ? <Empty /> : (
        <ul aria-label="Exchanged">
          {artifacts.map((artifact) => {
            const destination = destinationOf(artifact);
            return (
              <li key={artifact.id}>
                <button class="row entry" title="Right-click to show the message it came from"
                  onClick={() => {
                    if (destination.kind === "file" && insideScope(destination.path, roots)) {
                      const folder = destination.path.slice(0, destination.path.lastIndexOf("/")) || "/";
                      setPane(session, {
                        tab: "files", file: destination.path, fileLine: undefined, last: destination.path,
                        folder: root && folder === root ? undefined : folder,
                      });
                      return;
                    }
                    opened.value = artifact.id;
                  }}
                  onContextMenu={(event) => openContextMenu(event, [{
                    label: "Show the message it came from",
                    run: () => { focusedEntry.value = artifact.entryID; },
                  }])}
                  onKeyDown={(event) => {
                    if (isMenuKey(event)) openContextMenu(event, [{
                      label: "Show the message it came from",
                      run: () => { focusedEntry.value = artifact.entryID; },
                    }]);
                  }}>
                  <span class="title">{mark(destination.kind)} {artifact.name}</span>
                  <span class="subtitle">
                    {ago(fromWireDate(artifact.arrivedAt))}
                    {artifact.mimeType ? ` · ${artifact.mimeType}` : ""}
                    {artifact.size !== undefined ? ` · ${bytesInWords(artifact.size)}` : ""}
                    {missing.value.has(artifact.id) ? <span class="failure"> · no longer there</span> : null}
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
      {store.hasMoreOfTheConversation && (
        <p class="quiet small">Only what is in the part of the conversation read so far.</p>
      )}
    </div>
  );
}

function Reading({ artifact, back }: { artifact: Artifact; back: () => void }) {
  const destination = destinationOf(artifact);
  return (
    <div class="exchanged-doc">
      <div class="crumbs">
        <button class="link" onClick={back}>‹ Exchanged</button>
        <span class="title">{artifact.name}</span>
      </div>
      {destination.kind === "inPlace" && <article class="page"><Markdown text={artifact.text ?? ""} /></article>}
      {destination.kind === "web" && (
        <div>
          <p class="strong">{artifact.name}</p>
          <p class="quiet">It is on the web.</p>
          <a href={destination.href} target="_blank" rel="noopener noreferrer">{destination.href}</a>
        </div>
      )}
      {destination.kind === "file" && (
        <div>
          <p class="strong">{artifact.name}</p>
          <p class="quiet">It is a file on your Mac. Open it there.</p>
        </div>
      )}
      {destination.kind === "nowhere" && (
        <div>
          <p class="strong">{artifact.name}</p>
          <p class="quiet">The agent did not say where it is.</p>
        </div>
      )}
    </div>
  );
}

function Empty() {
  return (
    <div class="exchanged-empty">
      <p class="strong">Nothing exchanged yet</p>
      <p class="quiet">A file you attach to a prompt, or one an agent hands back by name, appears here, so you can find it again without scrolling back through the conversation.</p>
      <p class="faint">Files the agent merely changed are marked in Files instead.</p>
    </div>
  );
}

function mark(kind: ReturnType<typeof destinationOf>["kind"]): string {
  switch (kind) {
    case "web": return "🌐";
    case "inPlace": return "📝";
    case "nowhere": return "❓";
    case "file": return "📄";
  }
}
