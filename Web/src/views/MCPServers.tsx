// Every MCP server in one mcp.json and how each is doing (#753), as the window's MCPServersView and
// the Remote's MCPServersListView: the person's own under Activity, a folder's on its own page from
// its row in the sidebar. A folder's page opens with its set-up (#1336), and Connectors with
// the person's connections. Read-only but for Check Now and Remove… (#2154): servers are edited in Settings.
import { useState } from "preact/hooks";
import type { Store } from "../model/store";
import type { MCPLevels } from "../protocol/generated";
import {
  connectorLevels, fileProblem, healthKind, healthLastError, healthLine, healthTone, levelsSentence,
  notRemoved, notRemovedOffline, personalServers, folderEmpty, folderIntro, folderServers, removesCommitted, removesWords,
} from "../model/hostedMCP";
import { BackToList } from "./BackToList";
import { ConnectorSetupSection } from "./ConnectorSetup";
import { go } from "../route";
import { Capability } from "../protocol/capabilities.generated";
import { hostNeedsUpdate } from "../model/capabilities";

/** One host's servers from one file: the person's (no folder) or a folder's. */
export function MCPServersList({ store, host, folder }: { store: Store; host: string; folder?: string }) {
  const snapshot = store.mcpHealthOf(host);
  const servers = folder === undefined ? personalServers(snapshot) : folderServers(snapshot, folder);
  const problem = fileProblem(snapshot, folder);
  const [checking, setChecking] = useState(false);
  const [removeProblem, setRemoveProblem] = useState<string | undefined>();
  const checkable = servers.some((s) => !s.hosted);
  // Every connector (#2154), one written by hand in mcp.json too; asked first, as the window's sheet.
  // A server's is named (#2266); the Mac's is not.
  const machine = store.isMac(host) ? undefined : store.hosts.value.find((h) => h.id === host)?.name ?? host;
  const remove = async (name: string) => {
    const inFolder = folder !== undefined;
    if (!window.confirm(`Remove ${name}? ${removesWords(name, inFolder, machine)}${inFolder ? ` ${removesCommitted}` : ""}`)) return;
    const why = await store.removeConnector(host, name, folder);
    if (why === undefined) setRemoveProblem(undefined);
    else setRemoveProblem(store.hostIsOnline(host) ? notRemoved(name, why) : notRemovedOffline(name, machine ?? "This Mac"));
  };
  const checkNow = () => {
    setChecking(true);
    void store.checkMCPHealth(host, folder).finally(() => setChecking(false));
  };
  return (
    <div class="resources mcp-servers">
      {problem && <p class="small failure">{problem}</p>}
      {removeProblem && <p class="small failure">{removeProblem}</p>}
      {servers.length > 0 && (
        <ul>
          {servers.map((server) => {
            const tone = healthTone(server);
            const error = healthLastError(server);
            return (
              <li class="resource" key={`${server.folder ?? "~"}|${server.name}`}>
                <p>
                  <span class={`mcp-dot ${tone}`} aria-hidden="true" />{" "}
                  <span class="strong">{server.name}</span>{" "}
                  <span class="quiet small">{healthKind(server)}</span>
                </p>
                <p class="quiet small">{healthLine(server)}</p>
                {error && <p class={tone === "failing" ? "small failure" : "quiet small"}>{error}</p>}
                <ConnectorLevels levels={server.levels} />
                <button class="small" disabled={!store.hostIsOnline(host)} title={`Take ${server.name} out of its mcp.json`}
                  onClick={() => void remove(server.name)}>Remove…</button>
              </li>
            );
          })}
        </ul>
      )}
      {checkable && (
        <button disabled={checking || !store.hostIsOnline(host)} title="Check every connector that is not hosted again now"
          onClick={checkNow}>Check Now</button>
      )}
    </div>
  );
}

/** The five levels a connector reaches (#1428), as the window's ConnectorLevels. */
export function ConnectorLevels({ levels }: { levels: MCPLevels | undefined }) {
  const sentence = levelsSentence(levels);
  return (
    <p class="connector-levels" title={sentence} aria-label={sentence} role="img">
      {connectorLevels(levels).map((l) => (
        <span key={l.name} class={l.reached ? "reached" : undefined} aria-hidden="true">{l.name}</span>
      ))}
    </p>
  );
}

/** A folder's MCP servers, in the chat's place. */
export function MCPServersPage({ store, host, folder, folderName }: {
  store: Store; host: string; folder: string; folderName: string;
}) {
  const empty = folderServers(store.mcpHealthOf(host), folder).length === 0 && !fileProblem(store.mcpHealthOf(host), folder);
  return (
    <section class="chat activity-page mcp-page" aria-label={`${folderName}: Connectors`}>
      <header class="column-head"><BackToList /><h1>{folderName}: Connectors</h1></header>
      <div class="scroll">
        <div class="activity-body">
          {/* On a host too old to have it (#1748), the line that says so in its place (#1866). */}
          {store.has(host, Capability.connectorsSetup1)
            ? <ConnectorSetupSection store={store} host={host} folder={folder} folderName={folderName}
              go={(workflow) => go({ host, folder: folder, workflow })} />
            : <p class="hint">{hostNeedsUpdate}</p>}
          <h2 class="setup-heading">Folder connectors</h2>
          <MCPServersList store={store} host={host} folder={folder} />
          {empty && <p class="hint">{folderEmpty}</p>}
          <p class="hint">{folderIntro}</p>
        </div>
      </div>
    </section>
  );
}
