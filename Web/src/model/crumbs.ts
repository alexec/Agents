// The trail over a page's title (#2142), and the person's initial in the top bar.
import type { Route } from "../route";
import { navPages, navTitle, type NavSection } from "./nav";

export interface Crumb { title: string; to?: Route }

/** The person's initial, or a dot while it is not known. */
export function initialOf(name: string | undefined): string {
  const first = name?.trim().match(/\p{L}|\p{N}/u)?.[0];
  return first ? first.toLocaleUpperCase() : "•";
}

/** A page's breadcrumb: its section, then the page when its name is not the section's. */
export function pageCrumbs(section: Exclude<NavSection, "overview">, title: string): Crumb[] {
  return title === navTitle[section] ? [{ title }] : [{ title: navTitle[section], to: { nav: section } }, { title }];
}

/** The section an Activity page is in since #2141, for its breadcrumb; none for a page drawn inside another (Usage's panes). */
export function sectionOfActivity(page: string): Exclude<NavSection, "overview"> | undefined {
  return (Object.keys(navPages) as NavSection[]).find((s) => s !== "overview"
    && navPages[s].some((p) => p.draw.kind === "activity" && p.draw.page === page)) as Exclude<NavSection, "overview"> | undefined;
}
