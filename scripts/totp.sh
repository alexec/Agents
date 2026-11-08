#!/bin/sh
# Two-factor codes for the accounts agents sign in to (#3908), so a sign-in does not wait for
# Alex's passkey. The seed is in ~/.agents/secrets/<service>-totp, mode 600; this prints only
# the 6-digit code. Put it into a page with a script or fill_secret, never into a transcript.
#
#   scripts/totp.sh <service>                  the current code
#   … | scripts/totp.sh --save <service>       save a seed (base32 or otpauth://) from stdin
#   scripts/totp.sh --selftest                 check the library with RFC 6238's test vector
set -eu
dir=$(CDPATH= cd -- "$(dirname -- "$0")/totp" && pwd)
if [ ! -d "$dir/node_modules/otpauth" ]; then
  npm ci --prefix "$dir" --silent --no-audit --no-fund >&2
fi
exec node "$dir/totp.mjs" "$@"
