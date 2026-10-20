// The Simulator pane (#842; SimulatorPaneView): a simulator on the session's Mac, its screen read
// again each second while the pane shows and its tab is not hidden (#1650). Boot and Shut Down are the person's press only. A click
// on the screen is a touch there; Home is its button.
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { Store } from "../model/store";
import type { SimulatorList, SimulatorScreen } from "../protocol/generated";
import { describe } from "../model/errors";

export function SimulatorPane({ store, host }: { store: Store; host: string }) {
  const list = useSignal<SimulatorList | null>(null);
  const chosen = useSignal<string | null>(null);
  const screen = useSignal<SimulatorScreen | null>(null);
  const problem = useSignal<string | null>(null);
  /** Why the list could not be asked for: said in the middle with Try Again, not as "no simulators" (#1666). */
  const listProblem = useSignal<string | null>(null);
  /** Why the last screen read failed: the old frame is dimmed and says so (#1666). */
  const screenProblem = useSignal<string | null>(null);
  /** A boot or a shut-down sent and not yet done: said in the pane with a spinner (#1689). */
  const pending = useSignal<{ udid: string; booting: boolean } | null>(null);
  /** Counts touches, so the screen is read again at once after one. */
  const touches = useSignal(0);
  /** Whether the tab is hidden: then no screen is read (#1650). */
  const hidden = useSignal(document.hidden);
  const pane = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const seen = () => { hidden.value = document.hidden; };
    document.addEventListener("visibilitychange", seen);
    return () => document.removeEventListener("visibilitychange", seen);
  }, []);

  const reload = async () => {
    try {
      list.value = await store.link.call("simulators/list", {}, host);
      listProblem.value = null;
    } catch (error) {
      listProblem.value = describe(error);
    }
  };
  useEffect(() => { void reload(); }, [host]);

  const sims = list.value?.simulators ?? [];
  const simulator = sims.find((s) => s.udid === chosen.value) ?? sims[0];

  // A frame each second while this pane is on screen, its tab is not hidden and the simulator
  // is booted, as tall as the pane in pixels.
  useEffect(() => {
    screenProblem.value = null;
    if (!simulator?.booted) { screen.value = null; return; }
    if (hidden.value) return;
    let gone = false;
    const read = async () => {
      while (!gone) {
        try {
          const shot = await store.link.call("simulators/screen", { udid: simulator.udid, maxHeight: maxHeight(pane.current) }, host);
          if (!gone) { screen.value = shot; screenProblem.value = null; }
        } catch (error) {
          if (!gone) screenProblem.value = describe(error);
        }
        await new Promise((done) => setTimeout(done, 1000));
      }
    };
    void read();
    return () => { gone = true; };
  }, [host, simulator?.udid, simulator?.booted, touches.value, hidden.value]);

  const touch = async (method: "simulators/tap" | "simulators/home", params: { udid: string; x?: number; y?: number }) => {
    try {
      if (method === "simulators/tap") await store.link.call(method, params as { udid: string; x: number; y: number }, host);
      else await store.link.call(method, { udid: params.udid }, host);
      problem.value = null;
      setTimeout(() => { touches.value += 1; }, 250);
    } catch (error) {
      problem.value = describe(error);
    }
  };

  const toggle = async () => {
    if (!simulator) return;
    // Shut Down stops what runs on it: asked first (#1689).
    if (simulator.booted && !confirm(`Shut down ${simulator.name}?\n\nThe apps that run on it stop.`)) return;
    pending.value = { udid: simulator.udid, booting: !simulator.booted };
    try {
      await store.link.call(simulator.booted ? "simulators/shutdown" : "simulators/boot", { udid: simulator.udid }, host);
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    }
    chosen.value = simulator.udid;
    await reload();
    pending.value = null;
  };

  return (
    <div class="simulator-pane" ref={pane}>
      <div class="simulator-bar">
        {!listProblem.value && sims.length > 0 && (
          <select aria-label="Simulator" value={simulator?.udid} onChange={(e) => (chosen.value = (e.currentTarget as HTMLSelectElement).value)}>
            {sims.map((s) => <option key={s.udid} value={s.udid}>{`${s.name} · ${s.os}${s.booted ? "" : " · Shut Down"}`}</option>)}
          </select>
        )}
        <span class="spacer" />
        {!listProblem.value && simulator?.booted && !pending.value && <button class="link" title="Home" aria-label="Home" onClick={() => void touch("simulators/home", { udid: simulator.udid })}>⌂</button>}
        {!listProblem.value && simulator && <button class="link" disabled={pending.value !== null} onClick={() => void toggle()}>{simulator.booted ? "Shut Down" : "Boot"}</button>}
        <button class="link" title="List the simulators again" aria-label="List the simulators again" onClick={() => void reload()}>↻</button>
      </div>
      {listProblem.value ? <div class="simulator-problem"><p>Couldn't list the simulators: {listProblem.value}</p>
          <button onClick={() => void reload()}>Try Again</button></div>
        : list.value === null ? <p class="hint"><span class="spinner" /></p>
        : simulator && pending.value?.udid === simulator.udid
          ? <p class="hint"><span class="spinner" /> {pending.value.booting ? `Booting ${simulator.name}…` : `Shutting Down ${simulator.name}…`}</p>
        : !simulator ? <p class="hint">{list.value.reason ?? "This Mac has no iOS simulators. Make one in Xcode."}</p>
        : !simulator.booted ? <p class="hint">{simulator.name} is shut down. Boot it to see its screen.</p>
        : screen.value ? <>
          <img class={screenProblem.value ? "simulator-screen stale" : "simulator-screen"} alt={`The screen of ${simulator.name}`} width={screen.value.width} height={screen.value.height}
            title="A click here is a tap on the simulator" src={`data:image/jpeg;base64,${screen.value.jpeg}`}
            onClick={(e) => {
              const shown = (e.currentTarget as HTMLImageElement).getBoundingClientRect();
              if (!shown.width || !shown.height) return;
              const x = Math.min(Math.max((e.clientX - shown.left) / shown.width, 0), 1);
              const y = Math.min(Math.max((e.clientY - shown.top) / shown.height, 0), 1);
              void touch("simulators/tap", { udid: simulator.udid, x, y });
            }} />
          {screenProblem.value && <p class="failure small simulator-stale">Not updating: {screenProblem.value}</p>}
        </>
        : screenProblem.value ? <p class="failure simulator-stale">Not updating: {screenProblem.value}</p>
        : <p class="hint"><span class="spinner" /></p>}
      {problem.value && <p class="faint small">{problem.value}</p>}
    </div>
  );
}

/** The height to ask for: the pane's height in pixels, up in steps of 100. The host keeps it at most 1200. */
export function maxHeight(pane: { clientHeight: number } | null, ratio = window.devicePixelRatio || 1): number {
  return Math.max(100, Math.ceil(((pane?.clientHeight ?? 0) * ratio) / 100) * 100);
}
