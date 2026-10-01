// The web remote's entry point (spec 071).
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
session.start();
// A tab coming back into view tries again at once (contracts/browser-auth.md, "Closing").
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") session.link.retryNow();
});
