// Settings ▸ Browser (#3535): the machine's browser (#3533), one Chromium that agents on a machine drive
// with a kept profile. Its words, the same as BrowserSettingsWords in
// Packages/AgentsKit/Sources/AgentsKitCore/Model/BrowserSettings.swift, and what the section shows.
import type { BrowserState } from "../protocol/generated";
import { bytesInWords } from "./artifacts";

export const browserWords = {
  title: "Browser",
  sitesHeader: "Sites with sign-ins",
  sitesFooter: "Sites keep a sign-in in the browser's cookies. Agents on this machine use these sign-ins. Clear signs agents out of that site.",
  noSites: "No sites yet.",
  notDownloaded: "Not downloaded yet. The browser downloads the first time an agent uses it.",
  downloadHeader: "Download",
  downloadLabel: "Chromium",
  notDownloadedShort: "Not downloaded",
  downloadFooter: "One Chromium for this machine, which agents drive. It stops after 15 minutes with no use.",
  clear: "Clear",
  clearAll: "Clear All…",
  clearAllQuestion: "Clear every site's sign-ins?",
  clearAllDetail: "Agents on this machine are signed out of every site, and a person must sign in again.",
} as const;

/** A row's Clear, said with its site, so each one is told apart. */
export function clearSiteWords(site: string): string {
  return `Clear ${site}`;
}

export function cookiesWords(n: number): string {
  return n === 1 ? "1 cookie" : `${n} cookies`;
}

/** The download row: its size, or that there is none yet. */
export function downloadWords(state: BrowserState): string {
  return state.installed ? bytesInWords(state.downloadBytes) : browserWords.notDownloadedShort;
}

/** What the sites list says in place of rows, or null when it has rows to show. */
export function sitesNote(state: BrowserState): string | null {
  if (!state.installed) return browserWords.notDownloaded;
  if (state.problem) return state.problem;
  return state.sites.length === 0 ? browserWords.noSites : null;
}
