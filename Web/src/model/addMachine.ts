// Add a Machine… (#2131): one sheet with three ways in, a provider first; then a server, by one
// command; then another Mac, by a code. Connectors set-up ▸ Where agents run says the machine the
// folder is on and what else is yours. The window's and the Remote's AddMachine.swift is the same.

export type AddMachineWay = "provider" | "server" | "code";
export const addMachineWays: readonly AddMachineWay[] = ["provider", "server", "code"];

/** A machine name from what is typed: letters, digits and dashes, starting with a letter. */
export function validMachineName(text: string): boolean {
  return /^[A-Za-z][A-Za-z0-9-]{0,62}$/.test(text.trim());
}

export const addMachineWords = {
  title: "Add a Machine",
  menuItem: "Add a Machine…",
  addProvider: "Add Provider…",
  choice: (way: AddMachineWay) => ({ provider: "From a machine provider", server: "A server", code: "Another Mac" })[way],
  note: (way: AddMachineWay) => ({
    provider: "A new machine from Docker, DigitalOcean, Codespaces, Coder and the others. It joins by itself.",
    server: "Run one command on it. It connects out, so nothing has to reach it.",
    code: "Give it a code to join with. It works once.",
  })[way],
  noProviders: "No provider here can make a machine yet.",
  noProvidersAskAdmin: "No provider here can make a machine. An admin adds one in Settings ▸ Machine Providers.",
  providersYours: "Your providers are yours in every folder.",
  next: "Next",
  machineTitle: "New Machine",
  namePrompt: "build-2",
  repositoryOptional: "Clone a repository (optional)",
  nameNote: "Letters, digits and dashes, starting with a letter.",
  serverTitle: "Add a Machine",
  serverNote: "Run this on the machine. It installs Agents and joins as your machine. It works once.",
  codeTitle: "Add a Machine by Code",
  codeNote: "On the other machine, start its agents with agentsd --control-code and this code. It works once.",
  makingCode: "Making a code…",
  joined: (name: string) => `${name} joined. The code can’t be used again.`,
  machinesFoot: "Removing a machine stops it connecting. Its agents are left running where they are.",
  started: (name: string) => `${name} is starting. It installs Agents and joins on its first boot.`,
};

export const whereAgentsRun = {
  /** The slot's title: the machine the folder is on. */
  title: (onThisMac: boolean, hostName: string | null | undefined) => (onThisMac ? "This Mac" : hostName ?? "Its machine"),
  /** The slot's line: why it runs there, and what else is yours. */
  line(others: readonly string[], providers: readonly string[]): string {
    const parts = ["Agents run where this folder is."];
    if (others.length) parts.push(`Your other machines: ${others.join(", ")}.`);
    if (providers.length) parts.push(`Providers: ${providers.join(", ")}.`);
    return parts.join(" ");
  },
  hereNote: "This folder is here.",
  addMachineNote: "From a provider, a server or another Mac.",
  addProviderNote: `Docker, DigitalOcean, Codespaces, Coder and the others. ${addMachineWords.providersYours}`,
};
