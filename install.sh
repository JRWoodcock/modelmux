#!/usr/bin/env bash
# =============================================================================
# install.sh — modelmux installer
#
# Installs the modelmux MCP server so that Claude Code and Codex can call
# each other, and both can call Perplexity, directly from within a session.
#
# Works on any Mac (MacBook Air, Mac Mini, Apple Silicon, Intel).
# Run this script on each machine you want to use modelmux on.
#
# Usage:
#   bash install.sh
#
# What it does:
#   1. Checks that Node.js 18 or higher is installed
#   2. Copies the modelmux files to ~/.modelmux/
#   3. Prompts for API keys and saves them to ~/.zshrc
#   4. Registers modelmux with Claude Code and Codex via their MCP commands
#   5. Runs the connectivity and file I/O test to confirm everything works
#
# Author:  Jason R. Woodcock
# License: Apache-2.0 — see the LICENSE and NOTICE files.
# =============================================================================

set -e  # Exit immediately if any command fails

# Destination directory for the installed modelmux files
MODELMUX_DIR="$HOME/.modelmux"

# Shell profile where API keys are persisted between sessions
SHELL_RC="$HOME/.zshrc"

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
# Preflight: confirm Node.js 18+ is available
# ---------------------------------------------------------------------------

header "modelmux installer"
echo "  Installs the modelmux MCP server so Claude Code and Codex"
echo "  can call each other (and Perplexity) as tools."
echo ""

if ! command -v node &>/dev/null; then
  fail "Node.js was not found. Install v18 or higher from https://nodejs.org and re-run this script."
fi

NODE_VER=$(node -e "process.stdout.write(process.versions.node)")
MAJOR=$(echo "$NODE_VER" | cut -d. -f1)

if [ "$MAJOR" -lt 18 ]; then
  fail "Node.js v18 or higher is required. You have v${NODE_VER}. Update from https://nodejs.org"
fi

success "Node.js v${NODE_VER} found"

# ---------------------------------------------------------------------------
# Copy modelmux files to ~/.modelmux/
# ---------------------------------------------------------------------------

header "Installing modelmux files"

# Resolve the directory this script lives in, regardless of where it was called from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$MODELMUX_DIR/src"

cp "$SCRIPT_DIR/src/server.js" "$MODELMUX_DIR/src/server.js"
cp "$SCRIPT_DIR/src/test.js"   "$MODELMUX_DIR/src/test.js"
cp "$SCRIPT_DIR/package.json"  "$MODELMUX_DIR/package.json"

# Ensure the server is executable so it can be invoked directly if needed.
chmod +x "$MODELMUX_DIR/src/server.js"

success "Files installed to $MODELMUX_DIR"

# ---------------------------------------------------------------------------
# API keys
# ---------------------------------------------------------------------------

header "API keys"
echo "  You need at least one key. Press Enter to skip any you don't have yet."
echo "  Skipped keys can be added later by editing ~/.zshrc."
echo ""

# Prompt for a single API key and append it to ~/.zshrc if not already present.
# Arguments:
#   $1 — Human-readable label shown to the user
#   $2 — Environment variable name (e.g. ANTHROPIC_API_KEY)
#   $3 — URL where the key can be obtained
read_key() {
  local label="$1"
  local envvar="$2"
  local url="$3"

  # Check whether this key is already in the shell profile to avoid duplicates.
  local current
  current=$(grep "export ${envvar}=" "$SHELL_RC" 2>/dev/null | tail -1 \
    | sed "s/export ${envvar}=//;s/\"//g" || true)

  if [ -n "$current" ]; then
    echo -e "  ${GREEN}${envvar} is already set in ${SHELL_RC}${RESET} — skipping"
    return
  fi

  echo -e "  ${BOLD}${label}${RESET}"
  echo "  Get yours at: ${url}"
  printf "  Enter key (or press Enter to skip): "
  read -r key

  if [ -n "$key" ]; then
    echo "export ${envvar}=\"${key}\"" >> "$SHELL_RC"
    success "${envvar} saved to ${SHELL_RC}"
  else
    warn "${envvar} skipped. To add it later:"
    warn "  echo 'export ${envvar}=\"sk-...\"' >> ~/.zshrc"
  fi
  echo ""
}

read_key "Anthropic API key (needed for ask_claude and broker synthesis)" \
  "ANTHROPIC_API_KEY" \
  "https://console.anthropic.com/settings/keys"

read_key "OpenAI API key (needed for ask_codex)" \
  "OPENAI_API_KEY" \
  "https://platform.openai.com/api-keys"

read_key "Perplexity API key (needed for ask_perplexity)" \
  "PERPLEXITY_API_KEY" \
  "https://www.perplexity.ai/settings/api"

# Load the keys into the current shell session so the connectivity test can use them.
# The shellcheck disable comment suppresses a warning about sourcing a variable path,
# which is intentional here.
# shellcheck disable=SC1090
source "$SHELL_RC" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Build the list of --env flags for MCP registration.
#
# This is important for the Claude *Desktop app*: apps launched from the Dock do
# not load ~/.zshrc, so a server spawned by the app cannot see API keys exported
# there. Passing the keys as --env values stores them in the MCP server config so
# the server always finds them, regardless of how the host was launched.
#
# Only keys that are actually set are forwarded. (The keys were loaded into this
# shell by the `source "$SHELL_RC"` above.)
# ---------------------------------------------------------------------------

ENV_FLAGS=()
[ -n "$ANTHROPIC_API_KEY" ]  && ENV_FLAGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
[ -n "$OPENAI_API_KEY" ]     && ENV_FLAGS+=(-e "OPENAI_API_KEY=$OPENAI_API_KEY")
[ -n "$PERPLEXITY_API_KEY" ] && ENV_FLAGS+=(-e "PERPLEXITY_API_KEY=$PERPLEXITY_API_KEY")

# Locate a usable `claude` executable. Prefer one on PATH (the standalone CLI);
# otherwise fall back to the binary bundled inside the Claude Desktop app, which
# is not on PATH but works the same way for `mcp` subcommands. The highest
# version directory is chosen if several are installed.
find_claude() {
  if command -v claude &>/dev/null; then
    command -v claude
    return 0
  fi
  # Pick the most recently modified bundled binary (newest install). Uses BSD
  # `ls -t` for portability — macOS `sort` has no GNU `-V` version flag.
  local bundled
  bundled=$(ls -dt "$HOME/Library/Application Support/Claude/claude-code/"*/claude.app/Contents/MacOS/claude 2>/dev/null \
    | head -1)
  if [ -n "$bundled" ] && [ -x "$bundled" ]; then
    echo "$bundled"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Register with Claude Code
# ---------------------------------------------------------------------------

header "Registering with Claude Code"

CLAUDE_BIN=$(find_claude || true)

if [ -n "$CLAUDE_BIN" ]; then
  if "$CLAUDE_BIN" mcp list 2>/dev/null | grep -q "modelmux"; then
    warn "modelmux is already registered with Claude Code — skipping"
  # Register at user scope so modelmux is available in every project, with the
  # API keys baked in as env vars (see the ENV_FLAGS note above).
  elif "$CLAUDE_BIN" mcp add -s user "${ENV_FLAGS[@]}" modelmux -- node "$MODELMUX_DIR/src/server.js" 2>/dev/null; then
    success "Registered with Claude Code (user scope, keys included)"
    if ! command -v claude &>/dev/null; then
      info "Used the Claude Desktop app's bundled binary (no 'claude' CLI on PATH)."
    fi
  else
    warn "Claude registration failed. Register manually with:"
    warn "  \"$CLAUDE_BIN\" mcp add -s user ${ENV_FLAGS[*]:+<your -e keys>} modelmux -- node ${MODELMUX_DIR}/src/server.js"
  fi
else
  warn "No 'claude' command or Claude Desktop app was found. Skipping Claude registration."
  warn "Once Claude Code (CLI or Desktop app) is installed, register with:"
  warn "  claude mcp add -s user -e ANTHROPIC_API_KEY=... modelmux -- node ${MODELMUX_DIR}/src/server.js"
fi

# ---------------------------------------------------------------------------
# Register with Codex
# ---------------------------------------------------------------------------

header "Registering with Codex"

if command -v codex &>/dev/null; then
  if codex mcp list 2>/dev/null | grep -q "modelmux"; then
    warn "modelmux is already registered with Codex — skipping"
  else
    if codex mcp add modelmux -- node "$MODELMUX_DIR/src/server.js" 2>/dev/null; then
      success "Registered with Codex via 'codex mcp add'"
    else
      warn "Codex auto-registration failed. Once Codex is running, register manually:"
      warn "  codex mcp add modelmux -- node ${MODELMUX_DIR}/src/server.js"
    fi
  fi
else
  warn "The codex CLI was not found. Skipping Codex registration."
  warn "Once Codex is installed, run:"
  warn "  codex mcp add modelmux -- node ${MODELMUX_DIR}/src/server.js"
fi

# ---------------------------------------------------------------------------
# Connectivity and file I/O test
# ---------------------------------------------------------------------------

header "Running connectivity check"
node "$MODELMUX_DIR/src/test.js" || warn "Some checks did not pass — review the output above."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

header "Installation complete"
echo ""
echo "  Restart Claude Code and Codex to load the new MCP server."
echo "  Then use these tools from within either agent:"
echo ""
echo -e "  ${BOLD}ask_claude${RESET}     → Ask Claude a question or review a file"
echo -e "  ${BOLD}ask_codex${RESET}      → Ask OpenAI a question or review a file"
echo -e "  ${BOLD}ask_perplexity${RESET} → Search the web with Perplexity"
echo -e "  ${BOLD}broker${RESET}         → Query multiple AIs in parallel and synthesize the results"
echo ""
echo "  Example prompts:"
echo '    "Ask Claude to review /path/to/auth.php for security vulnerabilities"'
echo '    "Use the broker to get Claude and Codex opinions on this architecture"'
echo '    "Ask Perplexity what the latest WordPress REST API best practices are"'
echo ""
echo -e "  To install on another Mac: clone the repo and run ${BOLD}bash install.sh${RESET} again."
echo ""
success "Done. Run 'source ~/.zshrc' to load your API keys in the current terminal."
