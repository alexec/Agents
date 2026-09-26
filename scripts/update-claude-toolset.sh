#!/bin/zsh
# Pin the Claude toolset the app installs on this Mac (048) and on servers (043): Node.js and
# the ACP adapter, whose SDK carries a Claude binary per platform. See update-toolset.sh.
#
#   ./scripts/update-claude-toolset.sh <node-version> <claude-agent-acp-version>
#   ./scripts/update-claude-toolset.sh v24.21.0 0.81.2
set -euo pipefail

exec ${0:A:h}/update-toolset.sh claude "${1:?node version, e.g. v24.21.0}" \
  @agentclientprotocol/claude-agent-acp "${2:?claude-agent-acp version, e.g. 0.81.2}" \
  --platform-package claude-agent-sdk-
