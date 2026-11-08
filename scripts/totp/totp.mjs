// The code of a two-factor authenticator app (#3908), for an account an agent signs in to.
// The seed is in ~/.agents/secrets/<service>-totp (mode 600): a base32 key or an otpauth:// URI.
// It prints only the code, never the seed. The library is otpauth (MIT): it does the RFC 6238
// arithmetic, so this file only reads and writes the seed.
//
//   node totp.mjs <service>          print the current code
//   node totp.mjs --save <service>   read the seed on stdin and write the file, mode 600
//   node totp.mjs --selftest         check the RFC 6238 test vector
import { chmodSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { Secret, TOTP, URI } from "otpauth";

const fail = (message) => {
  console.error(`totp: ${message}`);
  process.exit(2);
};

const parse = (text) => {
  const seed = text.trim();
  if (seed.startsWith("otpauth://")) return URI.parse(seed);
  return new TOTP({ secret: Secret.fromBase32(seed.replace(/[\s-]/g, "").toUpperCase()) });
};

const [first, second] = process.argv.slice(2);
if (first === "--selftest") {
  // RFC 6238, appendix B: the ASCII key "12345678901234567890", SHA1, at 59 s is 94287082.
  const totp = new TOTP({ secret: Secret.fromLatin1("12345678901234567890"), digits: 8 });
  if (totp.generate({ timestamp: 59_000 }) !== "94287082") fail("selftest failed");
  console.log("ok");
  process.exit(0);
}
const service = first === "--save" ? second : first;
if (!service || !/^[a-z0-9][a-z0-9.-]*$/.test(service)) {
  fail("usage: totp.sh [--save] <service>   (a lower-case name, such as microsoft-agentstest)");
}
const file = join(homedir(), ".agents", "secrets", `${service}-totp`);

if (first === "--save") {
  const text = readFileSync(0, "utf8");
  try {
    parse(text);
  } catch {
    fail("stdin is not a base32 seed or an otpauth:// URI");
  }
  writeFileSync(file, `${text.trim()}\n`, { mode: 0o600 });
  chmodSync(file, 0o600);
  console.log(`saved ${file}`);
  process.exit(0);
}

let text;
try {
  if ((statSync(file).mode & 0o077) !== 0) fail(`${file} must be mode 600`);
  text = readFileSync(file, "utf8");
} catch (error) {
  if (error.code === "ENOENT") fail(`no seed: ${file}`);
  throw error;
}
let totp;
try {
  totp = parse(text);
} catch {
  fail(`${file} is not a base32 seed or an otpauth:// URI`);
}
console.log(totp.generate());
