// Lines for what only the Mac app does (#3425): with a Mac they send the person there; with
// none they say the web page cannot do it yet, not to use a Mac the person does not have.

/** Under Resources: where a resource is declared. */
export function resourcesHint(hasMac: boolean): string {
  return hasMac ? "Declared on the Mac, in Settings ▸ Resources. Agents lease one whenever its description applies."
    : "Agents lease one whenever its description applies. The web page cannot declare resources yet.";
}

/** The Resources page when no machine has one. */
export function noResourcesHint(hasMac: boolean): string {
  return hasMac ? "Nothing is declared or held. Resources are declared on the Mac, in Settings ▸ Resources."
    : "Nothing is declared or held. The web page cannot declare resources yet.";
}

/** Under Tokens and Spending: where the daily and per-agent limits are set. */
export function limitsHint(hasMac: boolean): string {
  return hasMac ? "Limits are set on the Mac." : "The web page cannot set limits yet.";
}

/** In a tool call's detail, for its terminal output, which the page does not draw. */
export function terminalOutput(hasMac: boolean): string {
  return hasMac ? "Terminal output is shown in the Mac window." : "The web page does not show terminal output yet.";
}
