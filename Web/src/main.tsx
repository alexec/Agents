// The web remote's entry point (spec 071).
import { render } from "preact";
import { App } from "./App";
import { Session } from "./session";

const session = new Session();
const root = document.getElementById("app");
if (root) render(<App session={session} />, root);
session.start();
// A tab coming back into view tries again at once (contracts/browser-auth.md, "Closing").
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") session.link.retryNow();
});
