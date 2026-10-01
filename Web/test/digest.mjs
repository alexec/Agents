// An item of the chat as the fixtures write it (WebFixturesTests.digest).
import { load } from "./load.mjs";

const turns = await load("src/model/turns.ts");

export function digest(item) {
  if (item.kind === "run") {
    return { run: item.id, calls: item.calls.map((call) => ({ id: call.toolCallID ?? null, title: call.title,
      status: call.status ?? null, turnLine: turns.turnLine(call) })) };
  }
  const out = { entry: item.id, kind: turns.kindOf(item.entry) };
  const body = item.entry.kind[out.kind];
  if (out.kind === "agentMessage" || out.kind === "agentThought") out.text = body.text;
  if (out.kind === "userMessage") out.text = body._0;
  return out;
}
