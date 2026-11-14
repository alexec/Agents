// The page's own rules, which src/app.css splits per view in src/styles/ (#5385): their text in
// the order app.css imports them, as it was one file before. Tests that read a rule read this.
import { readFileSync } from "node:fs";

const src = new URL("../src/", import.meta.url);

export const appCss = () =>
  [...readFileSync(new URL("app.css", src), "utf8").matchAll(/^@import "\.\/(styles\/[^"]+)";$/gm)]
    .map((m) => readFileSync(new URL(m[1], src), "utf8"))
    .join("");
