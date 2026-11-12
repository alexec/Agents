// The web remote's entry point (spec 071).
// First, so a code or an org provider's ticket in the address is gone before the router reads it (#109, #1002).
import { linkedCode, oidcBack } from "./pairLink";
import { render } from "preact";
import { App } from "./App";
import { Store } from "./model/store";
import { Session } from "./session";
import { startPresence } from "./presence";
import { dropWebPush, startPageNotices } from "./pageNotices";
import { forgetPins } from "./model/machineLock";
import { effect } from "@preact/signals";
import { startAgentLinks } from "./model/agentLink";
import { startSpinnerClock } from "./spinnerClock";
import { LocalCopy, setWorkCopy, startLocalCopy } from "./model/localCopy";

const session = new Session();
const store = new Store(session.link);
startPresence(store);
startPageNotices(store);
startAgentLinks(store);
startSpinnerClock();
// This device's copy of the sessions (#4790): drawn at once, written only while signed in.
const copy = new LocalCopy();
startLocalCopy(store, copy);
setWorkCopy(copy);
effect(() => {
  const kind = session.state.value.kind;
  if (kind === "open" || kind === "down") copy.writing = true;
});
// Forgotten, here or in another tab (#3670): the drafts, the lock pins and the push subscription
// were that control plane's, and go with it, as does the copy, deleted with the keys (#4790).
effect(() => {
  const kind = session.state.value.kind;
  if (kind === "unpaired" || kind === "pairing") copy.forget();
  if (kind !== "forgotten") return;
  copy.forget();
  store.drafts.clear();
  forgetPins();
  void dropWebPush();
});
const root = document.getElementById("app");
if (root) render(<App session={session} store={store} />, root);
session.start(linkedCode, oidcBack);
// A tab coming back into view tries again at once (contracts/browser-auth.md, "Closing"), or checks
// a link that stayed up while its heartbeat rested (#170).
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") session.link.retryNow();
});
// And so does the network coming back, as the window and the Remote do on a network change (#82).
addEventListener("online", () => session.link.retryNow());
// A code put in the address of a page already open changes only its fragment (#4129): load the
// page again, so the code is taken as at the start.
addEventListener("hashchange", () => {
  if (location.hash.startsWith("#code=")) location.reload();
});
