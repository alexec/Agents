// The Simulator pane (#842; SimulatorPaneView): a simulator on the session's Mac, its screen read
// again each second while the pane shows. Boot and Shut Down are the person's press only. It
// shows the screen; it does not take taps yet.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Store } from "../model/store";
import type { SimulatorList, SimulatorScreen } from "../protocol/generated";
import { describe } from "../model/errors";

export function SimulatorPane({ store, host }: { store: Store; host: string }) {
  const list = useSignal<SimulatorList | null>(null);
  const chosen = useSignal<string | null>(null);
  const screen = useSignal<SimulatorScreen | null>(null);
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);

  const reload = async () => {
    try {
      list.value = await store.link.call("simulators/list", {}, host);
      problem.value = null;
    } catch (error) {
      list.value = { simulators: [] };
      problem.value = describe(error);
    }
  };
  useEffect(() => { void reload(); }, [host]);

  const sims = list.value?.simulators ?? [];
  const simulator = sims.find((s) => s.udid === chosen.value) ?? sims[0];

  // A frame each second while this pane is on screen and the simulator is booted.
  useEffect(() => {
    screen.value = null;
    if (!simulator?.booted) return;
    let gone = false;
    const read = async () => {
      while (!gone) {
        try {
          const shot = await store.link.call("simulators/screen", { udid: simulator.udid }, host);
          if (!gone) { screen.value = shot; problem.value = null; }
        } catch (error) {
          if (!gone) problem.value = describe(error);
        }
        await new Promise((done) => setTimeout(done, 1000));
      }
    };
    void read();
    return () => { gone = true; };
  }, [host, simulator?.udid, simulator?.booted]);

  const toggle = async () => {
    if (!simulator) return;
    busy.value = true;
    try {
      await store.link.call(simulator.booted ? "simulators/shutdown" : "simulators/boot", { udid: simulator.udid }, host);
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    }
    chosen.value = simulator.udid;
    await reload();
    busy.value = false;
  };

  return (
    <div class="simulator-pane">
      <div class="simulator-bar">
        {sims.length > 0 && (
          <select aria-label="Simulator" value={simulator?.udid} onChange={(e) => (chosen.value = (e.currentTarget as HTMLSelectElement).value)}>
            {sims.map((s) => <option key={s.udid} value={s.udid}>{`${s.name} · ${s.os}${s.booted ? "" : " · Shut Down"}`}</option>)}
          </select>
        )}
        <span class="spacer" />
        {simulator && <button class="link" disabled={busy.value} onClick={() => void toggle()}>{simulator.booted ? "Shut Down" : "Boot"}</button>}
        <button class="link" title="List the simulators again" aria-label="List the simulators again" onClick={() => void reload()}>↻</button>
      </div>
      {list.value === null ? <p class="hint"><span class="spinner" /></p>
        : !simulator ? <p class="hint">{list.value.reason ?? "This Mac has no iOS simulators. Make one in Xcode."}</p>
        : !simulator.booted ? <p class="hint">{simulator.name} is shut down. Boot it to see its screen.</p>
        : screen.value ? <img class="simulator-screen" alt={`The screen of ${simulator.name}`} width={screen.value.width} height={screen.value.height}
            src={`data:image/jpeg;base64,${screen.value.jpeg}`} />
        : <p class="hint"><span class="spinner" /></p>}
      {problem.value && <p class="faint small">{problem.value}</p>}
    </div>
  );
}
