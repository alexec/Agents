// Connect to Another… on the page this Mac serves (#4257), in the window's words
// (`Packages/AgentsKit/Sources/AgentsKitCore/Control/ConnectAnother.swift`, #4228). The page asks
// the window on this Mac to do it (control/connectAnother): only the app there can stop this
// control plane and change the Mac's launch agents.

export const connectAnotherWords = {
  connect: "Connect to Another…",
  title: "Connect to another control plane",
  lead: "This Mac’s agents report to the control plane on this Mac. They can report to Hosted at agentloops.dev, or to a control plane that you run.",
  signIn: "Sign In to agentloops.dev",
  signInNote: "In Agents on this Mac, with Apple, Google or GitHub. A new account gets a control plane of its own.",
  useCode: "Use a Code…",
  useCodeNote: "From a control plane that you run: Settings ▸ Clients ▸ Pair a Mac there.",
  codeNote: "Paste the code. It works once, for five minutes.",
  notACode: "That isn’t a control plane’s code. It starts with agents-control:.",
  machineCode: "This is a code for a machine. Use a code from Pair a Mac on that control plane: Agents on this Mac makes this Mac’s machine code itself.",
  asking: "Asking Agents on this Mac…",
  hosted: "agentloops.dev",
} as const;

/** What happens, said before it does (the spec's words). */
export function connectBefore(place: string): string {
  return `This Mac’s agents will report to ${place}. Your sessions stay on this Mac. Your iPhone, iPad and browsers must pair again. The control plane on this Mac stops.`;
}

/** The page once this control plane has stopped: it served the page, so the page goes too. */
export function connectDone(place: string): string {
  return `This Mac’s agents now report to ${place}, and the control plane on this Mac has stopped, so this page has too. Use Agents in a browser there, and pair this browser again.`;
}

/** A pasted client code, with the control plane it is for, or why it will not do. */
export type CodeCheck = { code: string; place: string; url?: string } | { problem: string };

/**
 * As the window's `ConnectAnother.check` and `place`: agents-control:2:c:<grant>:<key>:<secret>:<url>:<pin>:<name>.
 * The place is the address's host name, such as `k3v9x0qa7b.cp.agentloops.dev`, else (an IP address,
 * `localhost`) the name the control plane gives itself.
 */
export function checkConnectCode(typed: string): CodeCheck {
  const code = typed.trim();
  const parts = code.split(":");
  if (parts.length !== 9 || parts[0] !== "agents-control" || parts[1] !== "2") return { problem: connectAnotherWords.notACode };
  if (parts[2] === "h") return { problem: connectAnotherWords.machineCode };
  if (parts[2] !== "c" || !parts[3]) return { problem: connectAnotherWords.notACode };
  let url: URL;
  let name: string;
  try {
    url = new URL(decodeURIComponent(parts[6]!));
    name = decodeURIComponent(parts[8]!);
  } catch {
    return { problem: connectAnotherWords.notACode };
  }
  const host = url.hostname;
  const named = host !== "localhost" && /[a-z]/i.test(host) && !host.includes(":") && !host.startsWith("[");
  const place = named ? host : name;
  return url.protocol === "https:" ? { code, place, url: url.origin } : { code, place };
}
