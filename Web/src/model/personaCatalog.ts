// Personas from a marketplace (#3665, #3678): the words the Mac's AddPersonaSheet and
// UpdatePersonaSheet say (App/Sources/Catalog), ported by hand, for the web page's sheets.
import type {
  CatalogError, DestinationState, Marketplace, PersonaPreview, PersonaSettingChange, SkillDestination, UpdateState,
} from "../protocol/generated";
import { Failure } from "../protocol/generated";
import type { CallFailed } from "../wire/link";
import { describe } from "./errors";

/** The daemon's own reason when it refused (its CatalogError as the failure's data), else the call's failure in words (AppModel.catalogError). */
export function catalogError(error: unknown): CatalogError {
  const { code, data } = (error ?? {}) as Partial<CallFailed>;
  if (code === Failure.catalogRefused && data && typeof data === "object") return data as CatalogError;
  return { failed: { _0: describe(error) } };
}

/** A path with the home folder as `~` when it is plainly one. */
function tilde(path: string): string {
  return path.replace(/^\/(Users|home)\/[^/]+(?=\/|$)/, "~");
}

/** A catalogue failure in words (CatalogErrorWords.sentence), as a persona's. */
export function catalogSentence(error: CatalogError): string {
  if ("unreachable" in error) return `Can't reach ${error.unreachable.host}.`;
  if ("rateLimited" in error) return "GitHub is limiting requests. Try again in a few minutes.";
  if ("unmanaged" in error) {
    return `You already have a persona at ${tilde(error.unmanaged.path)}. You made it, so the app won't replace it.`;
  }
  if ("lockUnreadable" in error) return `${tilde(error.lockUnreadable.path)} could not be read, so nothing was changed.`;
  if ("noPersonalHome" in error) return "This machine has no ~/.agents of its own.";
  if ("previewExpired" in error) return "That preview has expired. Open the persona again.";
  if ("notAFolder" in error) return `${tilde(error.notAFolder.path)} is not a folder on that machine.`;
  if ("replaceMismatch" in error) return "The persona there has changed since this was opened. Open it again.";
  if ("cannotAdd" in error) return "This persona can't be added.";
  if ("notManaged" in error) return `${error.notManaged.name} wasn't added from a marketplace.`;
  return `It couldn't be done: ${error.failed._0}`;
}

/** Only a GitHub repository holds persona files; skills.sh lists skills alone. */
export function personaMarketplaces(marketplaces: readonly Marketplace[]): Marketplace[] {
  return marketplaces.filter((m) => m.format === "github-skills");
}

/** The one chosen, or the first on when that one is gone or off (MarketplaceMenu.current). */
export function currentMarketplace(marketplaces: readonly Marketplace[], chosen: string): Marketplace | undefined {
  const on = marketplaces.filter((m) => m.enabled);
  return on.find((m) => m.id === chosen) ?? on[0];
}

export function hasUpdate(state: UpdateState | undefined): boolean {
  return state !== undefined && "available" in state;
}

/** Where the persona goes, as the preview's Goes to says it. */
export function goesTo(destination: SkillDestination, id: string): string {
  return destination.kind === "folder" && destination.folder
    ? `${tilde(destination.folder)}/.agents/personas/${id}.md`
    : `~/.agents/personas/${id}.md`;
}

/** The note above the preview about what is there already, or null when the place is free. */
export function destinationNote(preview: PersonaPreview): { text: string; attention: boolean } | null {
  const state: DestinationState = preview.destinationState;
  const id = preview.persona.id;
  if ("unmanaged" in state) {
    const folder = tilde(state.unmanaged.path.replace(/\/[^/]*$/, ""));
    return { text: `You already have a persona called ${id} in ${folder}. You made it, so the app won't replace it.`,
      attention: true };
  }
  if ("managedOther" in state) {
    return { text: `A persona of this name from ${state.managedOther.source} is there already. Adding this one replaces it.`,
      attention: false };
  }
  if ("sameSkill" in state) {
    return { text: state.sameSkill.update ? "An older copy of this persona is there. Adding replaces it with this commit."
      : "This persona is added already.", attention: false };
  }
  if ("unavailable" in state) return { text: catalogSentence(state.unavailable._0), attention: true };
  return null;
}

/** What the preview's button does: Add, Replace (after a question), nothing (Added) or none at all. */
export type AddAction = "add" | "replace" | "added" | "blocked" | "unmanaged";

export function addAction(preview: PersonaPreview): AddAction {
  const state = preview.destinationState;
  if ("unmanaged" in state) return "unmanaged";
  if ("sameSkill" in state) return state.sameSkill.update ? "replace" : "added";
  if ("managedOther" in state) return "replace";
  if ("unavailable" in state) return "blocked";
  return "add";
}

/** The runtime and the permission mode, old and new, in words (UpdatePersonaSheet.warning). */
export function settingWarning(change: PersonaSettingChange): string {
  const old = change.old ?? "not set";
  const next = change.new ?? "not set";
  if (change.key === "permission-mode") {
    return `This update changes the permission mode from ${old} to ${next}. New sessions with this persona start with it.`;
  }
  if (change.key === "runtime") {
    return `This update changes the runtime from ${old} to ${next}. New sessions with this persona run on it.`;
  }
  return `This update changes ${change.key} from ${old} to ${next}.`;
}

/** A managed persona's second line: where it is from, and its commit. */
export function sourceLine(persona: { source: string; commit?: string }): string {
  return [persona.source, persona.commit?.slice(0, 7)].filter(Boolean).join(" · ");
}
