// The person's agents' bot (#3858), under the GitHub row on Connectors, as the window's
// AgentsBotRow and MakeAgentsBotSheet. The host keeps the bot's key; the page sees its name only.
import { useEffect, useRef, useState } from "preact/hooks";
import type { Store } from "../model/store";
import type { ConnectionBot, ConnectionBotStart } from "../protocol/generated";
import { botCallback, botKeyOn, botNote, botWords } from "../model/connectorSetup";
import { Modal } from "./Modal";
import { ask } from "./MessageKinds";

function why(e: unknown): string {
  if (e && typeof e === "object" && "message" in e) return String((e as { message: unknown }).message);
  return String(e);
}

function openOut(address: string) {
  window.open(address, "_blank", "noopener");
}

/** The window the setup opens, so the hand-back page has an opener. */
const botWindow = "agents-bot";

export function AgentsBotRow({ store, host }: { store: Store; host: string }) {
  const [bot, setBot] = useState<ConnectionBot>();
  const [problem, setProblem] = useState<string>();
  const [making, setMaking] = useState(false);
  const load = async () => {
    try {
      setBot(await store.link.call("connections/bot", {}, host));
      setProblem(undefined);
    } catch (e) {
      setProblem(why(e));
    }
  };
  useEffect(() => { void load(); }, [host]);
  const forget = async () => {
    if (!await ask(`${botWords.removeTitle} ${botWords.removeMessage}`)) return;
    try {
      await store.link.call("connections/bot/remove", {}, host);
      if (bot?.appURL) openOut(bot.appURL);
    } catch (e) {
      setProblem(why(e));
    }
    await load();
  };
  return (
    <li class="connection">
      <span class="connector-mark soft" aria-hidden="true">B</span>
      <div class="grow">
        <p class="strong">{botWords.title}</p>
        <p class={`small ${problem ? "failure" : "quiet"}`}>{problem ?? (bot ? botNote(bot) : "…")}</p>
        {!problem && bot && botKeyOn(bot) && <p class="small quiet">{botKeyOn(bot)}</p>}
      </div>
      {bot?.made && bot.installURL && <button class="link small" onClick={() => openOut(bot.installURL!)}>{botWords.installButton}</button>}
      {bot?.made && <button class="destructive" onClick={() => void forget()}>{botWords.removeButton}</button>}
      {bot && !bot.made && <button onClick={() => setMaking(true)}>{botWords.makeButton}</button>}
      {making && <MakeAgentsBotDialog store={store} host={host} made={(b) => { setBot(b); void load(); }} close={() => setMaking(false)} />}
    </li>
  );
}

/**
 * Make your agents' bot: the host gives the manifest; the page posts it to GitHub in a window it
 * opened, and the hand-back page gives the code back by postMessage. The host takes the key.
 */
function MakeAgentsBotDialog({ store, host, made, close }: {
  store: Store; host: string; made: (bot: ConnectionBot) => void; close: () => void;
}) {
  type Step = { kind: "asking" } | { kind: "waiting" } | { kind: "finishing" } | { kind: "failed"; why: string };
  const [step, setStep] = useState<Step>({ kind: "asking" });
  const [isPublic, setPublic] = useState(false);
  const stopListening = useRef<(() => void) | undefined>(undefined);
  useEffect(() => () => stopListening.current?.(), []);

  const start = async () => {
    stopListening.current?.();
    // Open the window now, in the click, so that the browser does not block it. Without
    // noopener: the hand-back page sends the code to its opener.
    const popup = window.open("about:blank", botWindow);
    setStep({ kind: "waiting" });
    let started: ConnectionBotStart;
    try {
      started = await store.link.call("connections/bot/start", { origin: location.origin, public: isPublic }, host);
    } catch (e) {
      popup?.close();
      setStep({ kind: "failed", why: why(e) });
      return;
    }
    const listen = (event: MessageEvent) => {
      const answer = botCallback(event, started.state);
      if (!answer) return;
      stopListening.current?.();
      setStep({ kind: "finishing" });
      store.link.call("connections/bot/complete", answer, host).then((bot) => {
        if (!bot.made) {
          setStep({ kind: "failed", why: bot.message ?? "GitHub did not make the bot. Try again." });
          return;
        }
        made(bot);
        close();
      }, (e: unknown) => setStep({ kind: "failed", why: why(e) }));
    };
    window.addEventListener("message", listen);
    stopListening.current = () => {
      window.removeEventListener("message", listen);
      stopListening.current = undefined;
    };
    // GitHub's manifest flow takes a form post, not an address.
    const form = document.createElement("form");
    form.method = "post";
    form.action = started.action;
    form.target = botWindow;
    const field = document.createElement("input");
    field.type = "hidden";
    field.name = "manifest";
    field.value = started.manifest;
    form.appendChild(field);
    document.body.appendChild(form);
    form.submit();
    form.remove();
  };

  const busy = step.kind === "waiting" || step.kind === "finishing";
  return (
    <Modal label={botWords.sheetTitle} close={close}>
      <div class="sheet-body connect-sheet">
        <div class="connection">
          <span class="connector-mark" aria-hidden="true">B</span>
          <div>
            <p class="strong">{botWords.sheetTitle}</p>
            <p class="quiet small">{botWords.notMade}</p>
          </div>
        </div>
        <h2 class="setup-heading">The bot will be able to</h2>
        <ul class="abilities">{botWords.abilities.map((a) => <li key={a}>{a}</li>)}</ul>
        <p class="small quiet">{botWords.never}</p>
        <label class="field check">
          <input type="checkbox" checked={isPublic} disabled={busy} onChange={(e) => setPublic((e.target as HTMLInputElement).checked)} />
          {botWords.publicToggle}
        </label>
        <p class="small quiet">{botWords.publicHelp}</p>
        {busy && <p class="quiet small">{step.kind === "waiting" ? botWords.waiting : botWords.finishing}</p>}
        {step.kind === "failed" && <p class="small failure">{step.why}</p>}
        <div class="sheet-actions">
          <span class="quiet small grow">{botWords.keyNote}</span>
          <button onClick={close}>Cancel</button>
          {step.kind === "asking" && <button class="prominent" onClick={() => void start()}>{botWords.continueButton}</button>}
          {step.kind === "failed" && <button class="prominent" onClick={() => void start()}>Try Again</button>}
        </div>
      </div>
    </Modal>
  );
}
