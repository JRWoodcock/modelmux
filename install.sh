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
#   5. Adds a Codex tool-routing rule so "ask Claude/Perplexity" uses modelmux
#      instead of Computer Use (appended once to ~/.codex/AGENTS.md)
#   6. Runs the connectivity and file I/O test to confirm everything works
#
# Author:  Jason R. Woodcock
# License: Apache-2.0 — see the LICENSE and NOTICE files.
# =============================================================================

set -e  # Exit immediately if any command fails

# Resolve the directory this script lives in, regardless of where it was called
# from — used to locate the shared helper library and the files to install.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared helpers: colour output, host detection, node/key-flag building.
# shellcheck source=lib/common.sh
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  source "$SCRIPT_DIR/lib/common.sh"
else
  echo "Error: lib/common.sh was not found next to install.sh. Re-clone the repo." >&2
  exit 1
fi

# Destination directory for the installed modelmux files
MODELMUX_DIR="$HOME/.modelmux"

# Shell profile where API keys are persisted between sessions
SHELL_RC="$HOME/.zshrc"

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

mkdir -p "$MODELMUX_DIR/src" "$MODELMUX_DIR/lib"

cp "$SCRIPT_DIR/src/server.js" "$MODELMUX_DIR/src/server.js"
cp "$SCRIPT_DIR/src/test.js"   "$MODELMUX_DIR/src/test.js"
cp "$SCRIPT_DIR/package.json"  "$MODELMUX_DIR/package.json"

# Copy the key-refresh helper and the shared library it sources, so update-keys.sh
# can be run later from the install location.
[ -f "$SCRIPT_DIR/update-keys.sh" ] && cp "$SCRIPT_DIR/update-keys.sh" "$MODELMUX_DIR/update-keys.sh"
cp "$SCRIPT_DIR/lib/common.sh" "$MODELMUX_DIR/lib/common.sh"

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
# Prepare registration inputs
#
# Build the per-host --env flag arrays (ENV_FLAGS for Claude, CODEX_ENV_FLAGS for
# Codex) from the keys just loaded from ~/.zshrc, and resolve an absolute node
# path. Embedding the keys in the MCP config is what lets a Dock-launched Desktop
# app — which never reads ~/.zshrc — find them. See lib/common.sh for details.
# ---------------------------------------------------------------------------

build_env_flags
NODE_BIN=$(resolve_node)

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
  # NOTE: the server NAME must come before the -e flags. Claude's -e is variadic
  # and would otherwise swallow "modelmux" as an environment variable.
  elif "$CLAUDE_BIN" mcp add -s user modelmux "${ENV_FLAGS[@]}" -- "$NODE_BIN" "$MODELMUX_DIR/src/server.js" 2>/dev/null; then
    success "Registered with Claude Code (user scope, keys included)"
    if ! command -v claude &>/dev/null; then
      info "Used the Claude Desktop app's bundled binary (no 'claude' CLI on PATH)."
    fi
  else
    warn "Claude registration failed. Register manually with:"
    warn "  \"$CLAUDE_BIN\" mcp add -s user modelmux ${ENV_FLAGS[*]:+<your -e keys>} -- $NODE_BIN ${MODELMUX_DIR}/src/server.js"
  fi
else
  warn "No 'claude' command or Claude Desktop app was found. Skipping Claude registration."
  warn "Once Claude Code (CLI or Desktop app) is installed, register with:"
  warn "  claude mcp add -s user modelmux -e ANTHROPIC_API_KEY=... -- node ${MODELMUX_DIR}/src/server.js"
fi

# ---------------------------------------------------------------------------
# Register with Codex
# ---------------------------------------------------------------------------

header "Registering with Codex"

CODEX_BIN=$(find_codex || true)

if [ -n "$CODEX_BIN" ]; then
  if "$CODEX_BIN" mcp list 2>/dev/null | grep -q "modelmux"; then
    warn "modelmux is already registered with Codex — skipping"
  # Keys are embedded as env vars for the same reason as Claude (the Codex
  # Desktop app does not load ~/.zshrc). node is referenced by absolute path.
  elif "$CODEX_BIN" mcp add "${CODEX_ENV_FLAGS[@]}" modelmux -- "$NODE_BIN" "$MODELMUX_DIR/src/server.js" 2>/dev/null; then
    success "Registered with Codex (keys included)"
    if ! command -v codex &>/dev/null; then
      info "Used the Codex Desktop app's bundled binary (no 'codex' CLI on PATH)."
    fi
  else
    warn "Codex registration failed. Register manually with:"
    warn "  \"$CODEX_BIN\" mcp add ${CODEX_ENV_FLAGS[*]:+<your --env keys>} modelmux -- $NODE_BIN ${MODELMUX_DIR}/src/server.js"
  fi
else
  warn "No 'codex' command or Codex Desktop app was found. Skipping Codex registration."
  warn "Once Codex (CLI or Desktop app) is installed, register with:"
  warn "  codex mcp add --env OPENAI_API_KEY=... modelmux -- $NODE_BIN ${MODELMUX_DIR}/src/server.js"
fi

# ---------------------------------------------------------------------------
# Codex tool routing
#
# Codex's Computer Use plugin can interpret "ask Claude" as "open the Claude app
# on screen" instead of calling modelmux's ask_claude tool. This appends a small
# routing rule to Codex's global instructions (~/.codex/AGENTS.md) so "ask
# <model>" phrasing prefers the modelmux MCP tools, while Computer Use is left
# untouched for every other task.
#
# It is additive and safe: the block is fenced by a marker so it is added only
# once and never overwrites your own instructions. Remove the marked block to
# undo. Only runs when Codex is present.
# ---------------------------------------------------------------------------

if [ -n "$CODEX_BIN" ]; then
  header "Configuring Codex tool routing"

  CODEX_AGENTS="$HOME/.codex/AGENTS.md"
  ROUTING_MARKER="<!-- modelmux:tool-routing -->"

  if [ -f "$CODEX_AGENTS" ] && grep -qF "$ROUTING_MARKER" "$CODEX_AGENTS" 2>/dev/null; then
    warn "modelmux routing rule already present in ${CODEX_AGENTS} — skipping"
  else
    mkdir -p "$(dirname "$CODEX_AGENTS")"
    # Separate any existing content with a blank line, then append the marked
    # block. The heredoc is quoted ('EOF') so backticks are written literally.
    [ -s "$CODEX_AGENTS" ] && printf '\n' >> "$CODEX_AGENTS"
    {
      printf '%s\n' "$ROUTING_MARKER"
      cat <<'EOF'
## Tool routing: modelmux vs Computer Use (added by modelmux install.sh)

I have an MCP server named **modelmux** that calls other AI models through their
APIs. Its tools are: `ask_claude`, `ask_codex`, `ask_perplexity`, and `broker`.

When I ask you to "ask Claude", "ask Perplexity", get a second opinion from
another model, compare answers, or "use the broker", call the corresponding
**modelmux** MCP tool. These are API calls — for these requests do **not** use
the Computer Use plugin and do **not** open the Claude or Perplexity desktop apps.

Only use Computer Use to reach Claude/Perplexity when I explicitly say to "open"
the app, control the screen, or otherwise mention Computer Use. Keep using
Computer Use as normal for every other on-screen task — this rule narrows only
the "ask <model>" phrasing, nothing else.
EOF
    } >> "$CODEX_AGENTS"
    success "Added modelmux tool-routing rule to ${CODEX_AGENTS}"
  fi
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
