// A client code, as the Mac window and Agents Host show it (058 data-model.md "Code"):
// agents-control:2:c:<grant>:<key>:<secret>:<url>:<pin>:<name>
// The browser uses the key and the secret, and ignores the address and the pin: it always
// talks to the control plane that served the page (spec, Assumptions).
import { fromBase64url, hex } from "./bytes";

export interface ClientCode {
  grant: "operator" | "device";
  /** The control plane's public key, X9.63, 65 bytes. */
  controlKey: Uint8Array;
  /** 32 bytes: the code's id, then a tag. */
  secret: Uint8Array;
  /** The control plane's name, for the pairing screen. */
  name: string;
}

/** Null for anything that isn't a version 2 client code. */
export function parseCode(text: string): ClientCode | null {
  const parts = text.trim().split(":");
  if (parts.length !== 9 || parts[0] !== "agents-control" || parts[1] !== "2" || parts[2] !== "c") return null;
  const grant = parts[3];
  if (grant !== "operator" && grant !== "device") return null;
  const controlKey = fromBase64url(parts[4]!);
  const secret = fromBase64url(parts[5]!);
  if (!controlKey || controlKey.length !== 65 || controlKey[0] !== 4 || !secret || secret.length !== 32) return null;
  let name: string;
  try {
    name = decodeURIComponent(parts[8]!);
  } catch {
    return null;
  }
  return { grant, controlKey, secret, name };
}

/** `p:<hex of the secret's first 16 bytes>`, the identity a code holder proves. */
export function codeIdentity(code: ClientCode): string {
  return "p:" + hex(code.secret.slice(0, 16));
}
