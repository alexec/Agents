// A blocked agent's chat (039, #157): under its head, what it waits on, any of or all of, and
// when it checks again, as the window's row says it, with Carry on as the window's chat has it.
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { blockLines, carryOnHelp, carryOnLabel, carryOnPrompt, openBlock } from "../model/block";

export function BlockStrip({ store, host, agent, disabled }: { store: Store; host: string; agent: Agent | undefined; disabled: boolean }) {
  if (!agent || !openBlock(agent)) return null;
  const lines = blockLines(agent, store.agents.value[host] ?? []);
  return (
    <div class="block-strip" role="status" aria-label="What it waits on">
      {lines.length > 0 && <ul class="wait-lines">{lines.map((line) => <li key={line}>{line}</li>)}</ul>}
      <button class="carry-on" disabled={disabled} title={carryOnHelp(agent)}
        onClick={() => void store.prompt(host, agent.id, carryOnPrompt, [])}>▶ {carryOnLabel}</button>
    </div>
  );
}
