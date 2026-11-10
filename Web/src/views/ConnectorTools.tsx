// A connector's tools, each with Allow, Ask or Off, and one switch for every tool that writes (#4099), as
// the window's ConnectorToolsList: written to your layer for a connector of yours and to the folder's
// .agents/policy.json for one of the folder's. A layer above can only make them tighter, so a looser
// choice is kept and the cap's line says why it does not apply.
import { useEffect, useState } from "preact/hooks";
import type { Store } from "../model/store";
import type { ConnectorToolLevel, MCPToolsAnswer } from "../protocol/generated";
import {
  byDefault, capped, defaultToolLevel, eachTool, noTools, toolLevelHelp, toolLevels, toolLevelTitle, writesChip, writesTitle,
} from "../model/connectorTools";

export function ConnectorTools({ store, host, name, folder }: { store: Store; host: string; name: string; folder?: string | undefined }) {
  const [answer, setAnswer] = useState<MCPToolsAnswer | undefined>();
  const [failure, setFailure] = useState<string | undefined>();
  useEffect(() => {
    void store.connectorTools(host, name, folder).then((got) => {
      if (typeof got === "string") setFailure(got);
      else setAnswer(got);
    });
  }, [host, name, folder]);
  const set = async (tool: string | undefined, raw: string) => {
    const level = raw === "" ? undefined : (raw as ConnectorToolLevel);
    const got = await store.setConnectorToolLevel(host, name, tool, level, folder);
    if (typeof got === "string") setFailure(got);
    else {
      setAnswer(got);
      setFailure(undefined);
    }
  };
  const online = store.hostIsOnline(host);
  return (
    <div class="connector-tools">
      {answer === undefined && failure === undefined && <p class="quiet small">Loading its tools…</p>}
      {answer && (
        <>
          <p class="connector-tool writes-switch">
            <span class="strong small">{writesTitle}</span>
            {answer.writesCapLine && <span class="quiet small">{answer.writesCapLine}</span>}
            <select aria-label={`${writesTitle} of ${name}`} disabled={!online} value={answer.writes ?? ""}
              onChange={(e) => void set(undefined, (e.target as HTMLSelectElement).value)}>
              <option value="">{eachTool}</option>
              {toolLevels.map((l) => <option key={l} value={l}>{toolLevelTitle(l)}</option>)}
            </select>
          </p>
          {answer.problem && <p class="quiet small">{answer.problem}</p>}
          {!answer.problem && answer.tools.length === 0 && <p class="quiet small">{noTools}</p>}
          <ul>
            {answer.tools.map((row) => (
              <li class="connector-tool" key={row.name} title={toolLevelHelp(row.level)}>
                <span class="small">{row.name}</span>
                {row.title && <span class="quiet small">{row.title}</span>}
                {row.writes && <span class="chip small">{writesChip}</span>}
                {capped(row) && row.capLine && <span class="quiet small">{row.capLine}</span>}
                <select aria-label={`${row.name} of ${name}`} disabled={!online} value={row.own ?? ""}
                  onChange={(e) => void set(row.name, (e.target as HTMLSelectElement).value)}>
                  <option value="">{byDefault(defaultToolLevel(row, answer.writes))}</option>
                  {toolLevels.map((l) => <option key={l} value={l}>{toolLevelTitle(l)}</option>)}
                </select>
              </li>
            ))}
          </ul>
        </>
      )}
      {failure && <p class="small failure">{failure}</p>}
    </div>
  );
}
