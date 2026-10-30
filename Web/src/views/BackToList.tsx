// The way back to the one sidebar at a phone's width (#235), as the iPhone Remote's Back to its
// root list (#226). Hidden from 760, where the sidebar stays beside what it picked, and in a section
// other than Agents, whose list of pages stays above the page (#2141). It sets the address itself,
// as route.ts's go({ nav: "agents" }) would, so a view drawn without a page can still load it.
export function BackToList() {
  return <button class="back narrow-only" onClick={() => { if (location.hash !== "#/agents") location.hash = "#/agents"; }}>‹ Agents</button>;
}
