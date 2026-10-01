// The web remote's entry point (spec 071).
import { render } from "preact";
import { App } from "./App";
import { Model } from "./model";
import { Session } from "./session";

const session = new Session();
const model = new Model(session.link);
const root = document.getElementById("app");
if (root) render(<App session={session} model={model} />, root);
session.start();
// A tab coming back into view tries again at once (contracts/browser-auth.md, "Closing").
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") session.link.retryNow();
});
