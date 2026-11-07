#!/usr/bin/env bash
# Writes the App Store Connect key in ASC_KEY_P8 to the file $1, as a .p8 file that
# xcodebuild and scripts/asc.swift read. The workflows run it: `bash scripts/asc-key.sh FILE`.
#
# A secret pasted in a one-line field loses the .p8 file's line breaks, or has spaces in
# their place. So this keeps only the key's base64 text and wraps it again in 64-column
# lines between the BEGIN and END lines.
set -euo pipefail

out=${1:?usage: asc-key.sh FILE}
if [[ -z ${ASC_KEY_P8:-} ]]; then
  echo "::error::Set the secret ASC_KEY_P8 to the text of the .p8 file." >&2
  exit 1
fi
body=$(printf '%s' "$ASC_KEY_P8" | sed -e 's/-----[A-Z ]*-----//g' | tr -d ' \t\r\n')
if [[ -z $body || ! $body =~ ^[A-Za-z0-9+/=]+$ ]]; then
  echo "::error::ASC_KEY_P8 is not the text of a .p8 file. Set it again from the downloaded key." >&2
  exit 1
fi
{
  echo "-----BEGIN PRIVATE KEY-----"
  printf '%s\n' "$body" | fold -w 64
  echo "-----END PRIVATE KEY-----"
} > "$out"
