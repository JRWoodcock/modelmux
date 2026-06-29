#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — shared helpers for install.sh and update-keys.sh
#
# This file is *sourced*, not executed. It holds the logic both scripts need so
# that host detection and key handling live in exactly one place. It provides:
#
#   info / success / warn / fail / header  — coloured status output
#   find_claude / find_codex               — locate a CLI on PATH, or a Desktop
#                                            app's bundled binary as a fallback
#   resolve_node                           — echo an absolute path to node
#   build_env_flags                        — populate the ENV_FLAGS (Claude) and
#                                            CODEX_ENV_FLAGS (Codex) arrays from
#                                            the currently-exported API keys
#
# Author:  Jason R. Woodcock
# License: Apache-2.0 — see the LICENSE and NOTICE files.
# =============================================================================

# ---------------------------------------------------------------------------
# Terminal colour helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${BLUE}▸${RESET} $1"; }
success() { echo -e "${GREEN}✓${RESET} $1"; }
warn()    { echo -e "${YELLOW}⚠${RESET}  $1"; }
fail()    { echo -e "${RED}✗${RESET} $1"; exit 1; }
header()  { echo -e "\n${BOLD}$1${RESET}"; }

# ---------------------------------------------------------------------------
# Host detection
#
# Each host (Claude Code, Codex) may be installed as a CLI on PATH *or* only as a
# Desktop app whose binary is bundled inside the app and not on PATH. These
# helpers prefer the CLI and fall back to the bundled binary, which behaves the
# same for `mcp` subcommands. They echo the resolved path and return non-zero if
# nothing is found.
# ---------------------------------------------------------------------------

find_claude() {
  if command -v claude &>/dev/null; then
    command -v claude
    return 0
  fi
  # Pick the most recently modified bundled binary (newest install). Uses BSD
  # `ls -t` for portability — macOS `sort` has no GNU `-V` version flag.
  local bundled
  bundled=$(ls -dt "$HOME/Library/Application Support/Claude/claude-code/"*/claude.app/Contents/MacOS/claude 2>/dev/null | head -1)
  [ -n "$bundled" ] && [ -x "$bundled" ] && { echo "$bundled"; return 0; }
  return 1
}

find_codex() {
  if command -v codex &>/dev/null; then
    command -v codex
    return 0
  fi
  local candidate
  for candidate in \
    "$HOME/.codex/plugins/.plugin-appserver/codex" \
    "/Applications/Codex.app/Contents/Resources/codex" \
    "/Applications/Codex.app/Contents/MacOS/codex"; do
    [ -x "$candidate" ] && { echo "$candidate"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# Node + API-key handling
# ---------------------------------------------------------------------------

# Echo an absolute path to node. Dock-launched Desktop apps often lack the user's
# PATH (e.g. an nvm-managed node), so registering the server with a bare "node"
# can fail to launch it. Fall back to "node" if it cannot be resolved.
resolve_node() { command -v node 2>/dev/null || echo node; }

# Populate two global arrays of CLI flags from whichever API keys are currently
# exported: ENV_FLAGS for Claude (`-e KEY=VALUE`) and CODEX_ENV_FLAGS for Codex
# (`--env KEY=VALUE`). Embedding the keys in the MCP config is what lets a
# Desktop app — which never reads ~/.zshrc — still find them. Only keys that are
# actually set are forwarded.
build_env_flags() {
  ENV_FLAGS=()
  CODEX_ENV_FLAGS=()
  local key
  for key in ANTHROPIC_API_KEY OPENAI_API_KEY PERPLEXITY_API_KEY; do
    if [ -n "${!key}" ]; then
      ENV_FLAGS+=(-e "$key=${!key}")
      CODEX_ENV_FLAGS+=(--env "$key=${!key}")
    fi
  done
}
