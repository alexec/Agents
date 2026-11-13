// An agent's drive_screen paused by the person's own touch (#3004, US3, FR-007), as an Ask at the end
// of the transcript (#5031), with Resume and Take Over. The window and the Remote draw
// DesktopControlPauseCard.swift.
import { useSignal } from "@preact/signals";
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { pauseBody, pauseTitle, resumeLabel, takeOverHelp, takeOverLabel } from "../model/desktopControlWords";
import { Ask } from "./Ask";

export function DesktopControlPauseCard({ store, host, agent, disabled }: { store: Store; host: string; agent: Agent | undefined; disabled: boolean }) {
  const busy = useSignal(false);
  const pause = agent?.desktopControlPause;
  if (!agent || !pause) return null;
  const held = disabled || busy.value;
  const answer = (method: "desktopControl/resume" | "desktopControl/takeOver") => {
    busy.value = true;
    void store.answerDesktopControlPause(host, agent.id, method).finally(() => (busy.value = false));
  };
  const title = pauseTitle(pause.app);
  return (
    <Ask glyph="hand" title={title} label={title} alert
      buttons={<>
        <button disabled={held} title={takeOverHelp} onClick={() => answer("desktopControl/takeOver")}>{takeOverLabel}</button>
        <button class="prominent" disabled={held} data-default="" onClick={() => answer("desktopControl/resume")}>{resumeLabel}</button>
      </>}>
      <p class="quiet">{pauseBody}</p>
    </Ask>
  );
}
