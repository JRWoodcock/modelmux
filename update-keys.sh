#!/usr/bin/env bash
# =============================================================================
# update-keys.sh — re-sync API keys into the modelmux MCP registrations
#
# Desktop apps (Claude, Codex) do not read ~/.zshrc, so modelmux embeds your API
# keys directly in each app's MCP config when it is registered. If you later
# rotate or change a key in ~/.zshrc, the embedded copies go stale. Run this
# script to refresh them — it re-reads the keys from ~/.zshrc and re-registers
# modelmux with both apps (and the CLIs, if present).
#
# Usage:
#   bash update-keys.sh        # or: bash ~/.modelmux/update-keys.sh
#
# Restart Claude / Codex afterward (Cmd+Q, then reopen) so they reload the config.
#
# Author:  Jason R. Woodcock
# License: Apache-2.0 — see the LICENSE and NOTICE files.
# =============================================================================

set -e

SHELL_RC="$HOME/.zshrc"
MODELMUX_DIR="$HOME/.modelmux"
SERVER="$MODELMUX_DIR/src/server.js"

# Shared helpers (colour output, host detection, node/key-flag building). When run
# from the install location this resolves to ~/.modelmux/lib/common.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  source "$SCRIPT_DIR/lib/common.sh"
else
  echo "Error: lib/common.sh not found next to update-keys.sh. Re-run install.sh." >&2
  exit 1
fi

header "modelmux — refresh API keys"

# ---------------------------------------------------------------------------
# Load the current keys from the shell profile
# ---------------------------------------------------------------------------

# shellcheck disable=SC1090
source "$SHELL_RC" 2>/dev/null || true

if [ -z "$ANTHROPIC_API_KEY" ] && [ -z "$OPENAI_API_KEY" ] && [ -z "$PERPLEXITY_API_KEY" ]; then
  warn "No API keys found in ${SHELL_RC}. Nothing to sync."
  warn "Add at least one key (e.g. export OPENAI_API_KEY=\"sk-...\") and re-run."
  exit 1
fi

if [ ! -f "$SERVER" ]; then
  warn "Server not found at ${SERVER}. Run install.sh first."
  exit 1
fi

# Build the --env flag arrays and resolve an absolute node path (see lib/common.sh).
build_env_flags
NODE_BIN=$(resolve_node)

# ---------------------------------------------------------------------------
# Re-register with each host (remove first so the env block is replaced cleanly)
# ---------------------------------------------------------------------------

header "Updating Claude"
CLAUDE_BIN=$(find_claude || true)
if [ -n "$CLAUDE_BIN" ]; then
  "$CLAUDE_BIN" mcp remove modelmux &>/dev/null || true
  # Name must precede the variadic -e flags (else "modelmux" is read as an env var).
  if "$CLAUDE_BIN" mcp add -s user modelmux "${ENV_FLAGS[@]}" -- "$NODE_BIN" "$SERVER" &>/dev/null; then
    success "Claude keys refreshed."
  else
    warn "Could not update Claude. Register manually (see README)."
  fi
else
  warn "Claude not found — skipping."
fi

header "Updating Codex"
CODEX_BIN=$(find_codex || true)
if [ -n "$CODEX_BIN" ]; then
  "$CODEX_BIN" mcp remove modelmux &>/dev/null || true
  if "$CODEX_BIN" mcp add "${CODEX_ENV_FLAGS[@]}" modelmux -- "$NODE_BIN" "$SERVER" &>/dev/null; then
    success "Codex keys refreshed."
  else
    warn "Could not update Codex. Register manually (see README)."
  fi
else
  warn "Codex not found — skipping."
fi

header "Done"
echo "  Restart Claude / Codex (Cmd+Q, then reopen) to load the refreshed keys."
