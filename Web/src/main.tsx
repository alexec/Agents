// The web remote's entry point (spec 071).
// First, so a code in the address is gone before the router reads it (#109).
import { linkedCode } from "./pairLink";
import { render } from "preact";
import { App } from "./App";
import { Store } from "./model/store";
import { Session } from "./session";
import { startPresence } from "./presence";

const session = new Session();
const store = new Store(session.link);
startPresence(store);
const root = document.getElementById("app");
if (root) render(<App session={session} store={store} />, root);
session.start(linkedCode);
// A tab coming back into view tries again at once (contracts/browser-auth.md, "Closing"), or checks
// a link that stayed up while its heartbeat rested (#170).
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") session.link.retryNow();
});
// And so does the network coming back, as the window and the Remote do on a network change (#82).
addEventListener("online", () => session.link.retryNow());
