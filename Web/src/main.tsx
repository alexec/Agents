// The web remote's entry point (spec 071). Phase 2 renders a name only; pairing (US1) and the
// three columns (US2) arrive in later tasks.
import { render } from "preact";

const root = document.getElementById("app");
if (root) render(<main><h1>Agents</h1></main>, root);
