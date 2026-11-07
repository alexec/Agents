#!/bin/bash
# The registry of outside accounts the agents made or use (#3909): one JSON file per
# account in ~/.agents/accounts/ (AGENTS_ACCOUNTS_DIR moves it). The sign-up skill reads it
# before it makes an account and writes a file when it makes one.
#
#   accounts.sh list     a row per account, then the total monthly cost
#   accounts.sh check    exit 1 when a file is not valid or holds a secret
#
# A file, for example gitlab.json:
#   {
#     "service": "gitlab.com",
#     "address": "agentstest@alexecollins.com",
#     "plan": "Free",
#     "monthly_cost_usd": 0,
#     "card": null,
#     "secret": "~/.agents/secrets/gitlab-token",
#     "two_factor": null,
#     "issue": 1634,
#     "made": "2026-10-19",
#     "token_expires": "2027-10-18",
#     "notes": "Password in Keychain agents-signup:gitlab.com#agentstest@alexecollins.com"
#   }
# card is the Privacy.com card's nickname, never its number. secret is where the secret is,
# never its value. two_factor is TOTP, passkey, SMS or null. Unknown values are null.
set -euo pipefail

die() { echo "accounts.sh: $*" >&2; exit 1; }

DIR=${AGENTS_ACCOUNTS_DIR:-$HOME/.agents/accounts}
cmd=${1:-list}
case $cmd in
  list|check) ;;
  -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
  *) die "unknown command '$cmd' (list, check)" ;;
esac
[[ -d $DIR ]] || die "no registry at $DIR"

exec python3 - "$cmd" "$DIR" <<'PY'
import glob, json, os, re, sys

cmd, folder = sys.argv[1], sys.argv[2]
FIELDS = ["service", "address", "plan", "monthly_cost_usd", "card", "secret",
          "two_factor", "issue", "made", "token_expires", "notes"]
# Values that look like a secret: a known token prefix, a card number, a PEM key.
SECRET = re.compile(r"(glpat-|dop_v1_|xox[abp]-|xapp-|ghp_|github_pat_|AKIA[0-9A-Z]{12}"
                    r"|-----BEGIN|\b(?:\d[ -]?){13,19}\b)")

rows, problems = [], []
for path in sorted(glob.glob(os.path.join(folder, "*.json"))):
    name = os.path.basename(path)[:-5]
    try:
        with open(path) as f:
            acct = json.load(f)
    except (OSError, ValueError) as e:
        problems.append(f"{name}: not valid JSON ({e})")
        continue
    if not isinstance(acct, dict):
        problems.append(f"{name}: not a JSON object")
        continue
    extra = sorted(set(acct) - set(FIELDS))
    if extra:
        problems.append(f"{name}: unknown fields {', '.join(extra)}")
    if not acct.get("service"):
        problems.append(f"{name}: no service")
    cost = acct.get("monthly_cost_usd")
    if cost is not None and not isinstance(cost, (int, float)):
        problems.append(f"{name}: monthly_cost_usd is not a number")
        cost = None
    if any(isinstance(v, str) and SECRET.search(v) for v in acct.values()):
        problems.append(f"{name}: a value looks like a secret; write where it is, not the value")
    rows.append((name, acct, cost))

for p in problems:
    print(f"accounts.sh: {p}", file=sys.stderr)
if cmd == "check":
    sys.exit(1 if problems else 0)

def text(v):
    return "-" if v is None or v == "" else str(v)

head = ["NAME", "SERVICE", "ADDRESS", "PLAN", "$/MONTH", "CARD", "2FA", "ISSUE", "MADE", "EXPIRES"]
table = [head]
total = 0.0
for name, a, cost in rows:
    total += cost or 0
    table.append([name, text(a.get("service")), text(a.get("address")), text(a.get("plan")),
                  "-" if cost is None else f"{cost:g}", text(a.get("card")),
                  text(a.get("two_factor")),
                  "-" if a.get("issue") is None else f"#{a['issue']}",
                  text(a.get("made")), text(a.get("token_expires"))])
widths = [max(len(r[i]) for r in table) for i in range(len(head))]
for r in table:
    print("  ".join(c.ljust(w) for c, w in zip(r, widths)).rstrip())
unknown = sum(1 for _, _, c in rows if c is None)
print(f"\n{len(rows)} accounts, ${total:g} a month" +
      (f" ({unknown} with no known cost)" if unknown else ""))
PY
