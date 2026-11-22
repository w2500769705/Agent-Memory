#!/bin/sh
set -eu
resources=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bridge="$resources/../MacOS/agent-memory-mcp"
codex=$("$bridge" --locate-codex)
printf '%s\n' 'Agent Memory Hook review' \
  'Choose Review hooks, or enter /hooks inside Codex.' \
  'Open UserPromptSubmit and review the Agent Memory command, then press t to trust it.'
exec "$codex" --cd "$HOME" --no-alt-screen
