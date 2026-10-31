/**
 * An agent's ask_secret (#2885), in the words the window's and the Remote's SecretAskCard use:
 * what goes under the masked field, and the link to where the secret is got.
 */
import type { ElicitationSecret } from "../protocol/generated";

/** The one field of a secret's form, as the host names it. */
export const secretField = "value";

/** Under the field: where it goes, and that the agent never sees it. */
export function keeping(secret: ElicitationSecret, recipient: string): string {
  const replaces = secret.isSet ? " It replaces the one saved there." : "";
  return `Saved to your secrets on ${recipient}.${replaces} The agent gets its name, never the value.`;
}

/** "Get it at platform.openai.com", or null for no link or one that is not a web page. */
export function getIt(url: string | undefined): string | null {
  if (!url) return null;
  try {
    const u = new URL(url);
    return u.protocol === "https:" || u.protocol === "http:" ? `Get it at ${u.host}` : null;
  } catch {
    return null;
  }
}
