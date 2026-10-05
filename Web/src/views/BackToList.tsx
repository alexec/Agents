// The way back to the one sidebar at a phone's width (#235), as the iPhone Remote's Back to its
// root list (#226). Hidden from 760, where the sidebar stays beside what it picked. It sets the
// address itself, as route.ts's go({}) would, so a view drawn without a page can still load it.
export function BackToList() {
  return <button class="back narrow-only" onClick={() => { if (location.hash !== "#/") location.hash = "#/"; }}>‹ Agents</button>;
}
