// Every MCP server in one mcp.json and how each is doing (#753), as the window's MCPServersView and
// the Remote's MCPServersListView: the person's own under Activity, a project's on its own page from
// its row in the sidebar. Read-only but for Check Now: servers are edited in Settings.
import { useState } from "preact/hooks";
import type { Store } from "../model/store";
import type { MCPLevels } from "../protocol/generated";
import {
  connectorLevels, fileProblem, healthKind, healthLastError, healthLine, healthTone, levelsSentence, madeByAgents,
  personalServers, projectEmpty, projectIntro, projectServers,
} from "../model/hostedMCP";
import { BackToList } from "./BackToList";

/** One host's servers from one file: the person's (no folder) or a project's. */
export function MCPServersList({ store, host, folder }: { store: Store; host: string; folder?: string }) {
  const snapshot = store.mcpHealthOf(host);
  const servers = folder === undefined ? personalServers(snapshot) : projectServers(snapshot, folder);
  const problem = fileProblem(snapshot, folder);
  const [checking, setChecking] = useState(false);
  const checkable = servers.some((s) => !s.hosted);
  const checkNow = () => {
    setChecking(true);
    void store.checkMCPHealth(host, folder).finally(() => setChecking(false));
  };
  return (
    <div class="resources mcp-servers">
      {problem && <p class="small failure">{problem}</p>}
      {servers.length > 0 && (
        <ul>
          {servers.map((server) => {
            const tone = healthTone(server);
            const error = healthLastError(server);
            return (
              <li class="resource" key={`${server.project ?? "~"}|${server.name}`}>
                <p>
                  <span class={`mcp-dot ${tone}`} aria-hidden="true" />{" "}
                  <span class="strong">{server.name}</span>{" "}
                  {server.madeByAgents && <><span class="made-by-agents">{madeByAgents}</span>{" "}</>}
                  <span class="quiet small">{healthKind(server)}</span>
                </p>
                <p class="quiet small">{healthLine(server)}</p>
                {error && <p class={tone === "failing" ? "small failure" : "quiet small"}>{error}</p>}
                <ConnectorLevels levels={server.levels} />
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

/** A project's MCP servers, in the chat's place. */
export function MCPServersPage({ store, host, folder, projectName }: {
  store: Store; host: string; folder: string; projectName: string;
}) {
  const empty = projectServers(store.mcpHealthOf(host), folder).length === 0 && !fileProblem(store.mcpHealthOf(host), folder);
  return (
    <section class="chat activity-page mcp-page" aria-label={`${projectName}: Connectors`}>
      <header class="column-head"><BackToList /><h1>{projectName}: Connectors</h1></header>
      <div class="scroll">
        <div class="activity-body">
          <p class="hint">{projectIntro}</p>
          <MCPServersList store={store} host={host} folder={folder} />
          {empty && <p class="hint">{projectEmpty}</p>}
        </div>
      </div>
    </section>
  );
}
