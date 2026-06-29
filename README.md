# modelmux

> An MCP server that lets Claude Code, Codex, and Perplexity call each other as tools — directly from your terminal, mid-session, without switching windows. Supports text, code, images, and PDFs passed by file path.

**Author:** Jason R. Woodcock
**Version:** 2.0.0
**License:** Apache-2.0 — see [LICENSE](LICENSE)

Instead of copy-pasting between AI tools, you can say things like:

```
Ask Codex to review this function and compare it to your approach
```
```
Use the broker to get Claude and Codex opinions on this architecture, then synthesize a recommendation
```
```
Ask Claude to review /Users/you/project/auth.php for security vulnerabilities
```
```
Use the broker to analyse /Users/you/docs/architecture.pdf and suggest improvements
```
```
Ask Perplexity what the current best practices are for WordPress REST API auth
```

---

## How it works

modelmux is a small [MCP (Model Context Protocol)](https://modelcontextprotocol.io) server. Both Claude Code and Codex support MCP natively — when you register modelmux, it appears as a set of callable tools inside both agents. When you invoke one of those tools, modelmux makes a direct API call to the target AI and returns the response inline into your current session.

**It runs on-demand only.** The modelmux process starts when you open Claude Code or Codex, and stops when you close them. Nothing runs in the background.

**It uses API keys, not subscription quota.** Calls go through your Anthropic/OpenAI/Perplexity API accounts at pay-per-token rates — completely separate from your Claude Code or Codex subscription limits. Light use (a few cross-reviews per day) typically costs under $5/month across all three APIs.

---

## Prerequisites

- macOS (tested on MacBook Air and Mac Mini; Apple Silicon and Intel both work)
- [Node.js](https://nodejs.org) v18 or higher
- [Claude Code](https://claude.ai/code) and/or [Codex CLI](https://developers.openai.com/codex) installed
- API keys for the services you want to use (you can skip any you don't need)

---

## Installation

### Quick install

```bash
git clone https://github.com/JRWoodcock/modelmux.git
cd modelmux
bash install.sh
```

The installer will:
1. Check for Node.js 18+
2. Prompt you for API keys and save them to `~/.zshrc`
3. Register modelmux with Claude Code and Codex automatically
4. Run a connectivity test against each API

Then restart Claude Code and/or Codex to pick up the new MCP server.

> **Using the Claude Desktop app?** It works, with two caveats the installer
> handles automatically: there's no `claude` command on your PATH (the installer
> finds the app's bundled binary instead), and the app can't read API keys from
> `~/.zshrc` (so the keys are baked into the server's config at registration).
> After installing, **fully quit the app with Cmd+Q** — not just closing the
> window — then reopen it. modelmux appears under **Settings → MCP** as a *user*
> server (available in every project). See [Troubleshooting](#troubleshooting) if
> it doesn't show up.

### Install from npm

The server is also published to npm. This gives you the `modelmux` command
without cloning, but does not set up API keys or register the server — run those
steps yourself (see [API keys](#api-keys) and the registration commands below).

```bash
npm install -g @jrwoodcock/modelmux

# Register the installed command with each agent:
claude mcp add modelmux -- modelmux
codex mcp add modelmux -- modelmux
```

The package name is scoped (`@jrwoodcock/modelmux`), but the installed command
is just `modelmux`.

### Installing on multiple Macs

Same steps on each machine. The installer creates `~/.modelmux/` locally from the cloned repo. Your API keys are stored in `~/.zshrc` on each machine separately — enter them fresh on each install (or sync your dotfiles if you already do that).

```bash
# On your second Mac:
git clone https://github.com/JRWoodcock/modelmux.git
cd modelmux
bash install.sh
```

### Manual registration (if the installer skipped a tool)

If Claude Code or Codex wasn't found during install, register manually after installing them.

**Claude Code (CLI):** register at user scope and pass your keys as `--env` values, so the server has them no matter how the host is launched:
```bash
claude mcp add -s user \
  -e ANTHROPIC_API_KEY="sk-ant-..." \
  -e OPENAI_API_KEY="sk-..." \
  -e PERPLEXITY_API_KEY="pplx-..." \
  modelmux -- node ~/.modelmux/src/server.js
```

**Claude Desktop app (no `claude` on PATH):** the app bundles the CLI — call it directly with the same arguments:
```bash
"$HOME/Library/Application Support/Claude/claude-code/"*/claude.app/Contents/MacOS/claude \
  mcp add -s user -e ANTHROPIC_API_KEY="sk-ant-..." -e OPENAI_API_KEY="sk-..." \
  -e PERPLEXITY_API_KEY="pplx-..." modelmux -- node ~/.modelmux/src/server.js
```

> **Why `--env`?** The Claude Desktop app is launched from the Dock, so it does
> **not** load `~/.zshrc` — a server it spawns can't see API keys exported there.
> Passing the keys with `-e` stores them in the MCP config so they're always
> found. Trade-off: if you later rotate a key in `~/.zshrc`, re-run the
> registration (or edit the entry) so the stored copy is updated too.

**Codex:**
```bash
codex mcp add modelmux -- node ~/.modelmux/src/server.js
```
(Codex runs from your terminal, so it inherits keys from `~/.zshrc` — no `--env` needed.)

After registering, **fully quit and reopen** Claude Code / the Desktop app (Cmd+Q, not just closing the window) so it loads the new server.

---

## API keys

The installer prompts for these interactively. To set or update them manually:

```bash
# Add to ~/.zshrc
export ANTHROPIC_API_KEY="sk-ant-..."    # console.anthropic.com/settings/keys
export OPENAI_API_KEY="sk-..."           # platform.openai.com/api-keys
export PERPLEXITY_API_KEY="pplx-..."     # perplexity.ai/settings/api
```

Then `source ~/.zshrc` and restart Claude Code / Codex.

You only need keys for the tools you plan to use. The `broker` tool's synthesis step uses Claude, so `ANTHROPIC_API_KEY` is the most important one.

### Optional model overrides

```bash
export ANTHROPIC_MODEL="claude-sonnet-4-6"   # default
export OPENAI_MODEL="gpt-4o"                  # default
export PERPLEXITY_MODEL="sonar-pro"           # default
```

---

## Tools

Once registered, both Claude Code and Codex can call these tools naturally during a conversation:

| Tool | Description |
|---|---|
| `ask_claude` | Send a prompt to Claude (Anthropic API), optionally with a file |
| `ask_codex` | Send a prompt to OpenAI (GPT-4o by default), optionally with a file |
| `ask_perplexity` | Send a prompt to Perplexity with live web search, optionally with a text/code file |
| `broker` | Query multiple AIs in parallel with the same prompt and file, optionally synthesize into one response |

All tools accept:
- `prompt` — required, the question or instruction
- `system` — optional system prompt to set the AI's role (e.g. `"You are a security expert reviewing code for vulnerabilities"`)
- `file` — optional absolute or relative path to a file on disk (see file support below)

The `broker` tool also accepts:
- `targets` — array of `"claude"`, `"codex"`, `"perplexity"` (default: `["claude", "codex"]`)
- `synthesize` — `true` (default) to get a synthesized summary, `false` for raw side-by-side responses

### File support

Pass any local file by path and modelmux will read, encode, and send it to the target AI automatically.

| File type | Extensions | ask_claude | ask_codex | ask_perplexity | broker |
|---|---|---|---|---|---|
| Code / text | `.js` `.ts` `.php` `.py` `.md` `.txt` `.json` `.css` `.html` `.sql` and more | ✅ | ✅ | ✅ | ✅ all targets |
| Images | `.png` `.jpg` `.jpeg` `.gif` `.webp` | ✅ vision API | ✅ vision API | ⚠️ skipped with note | ✅ Claude + Codex only |
| PDFs | `.pdf` | ✅ document API | ✅ inline base64 | ⚠️ skipped with note | ✅ Claude + Codex only |

When a broker call includes an image or PDF and Perplexity is a target, Perplexity receives a transparent note that a binary file was attached but not forwarded — it answers on the text prompt alone rather than silently failing.

**Size limit:** 20 MB per file. A clear error is returned if the limit is exceeded.

---

## Usage examples

Use these prompts naturally inside Claude Code or Codex — the agent will call the appropriate tool automatically.

### Cross-review (text prompt)

```
Ask Codex to review this function and tell me if it agrees with your approach:

function parseDate(str) {
  return new Date(str);
}
```

### Cross-review (file path)

```
Ask Claude to review /Users/you/project/auth.php for security vulnerabilities
```

```
Ask Codex to refactor /Users/you/project/utils.js and suggest a cleaner approach
```

### Image analysis

```
Ask Claude to describe the UI layout in /Users/you/Desktop/mockup.png and
suggest accessibility improvements
```

```
Use the broker to get both Claude and Codex opinions on the architecture
diagram at /Users/you/docs/system-diagram.png
```

### PDF review

```
Ask Claude to summarise the key decisions in /Users/you/docs/proposal.pdf
```

```
Use the broker to analyse /Users/you/docs/architecture.pdf and identify
any risks, with Claude and Codex each giving their perspective
```

### Parallel opinions with synthesis

```
Use the broker to get both Claude and Codex opinions on whether I should use
PostgreSQL or MongoDB for a WordPress plugin that stores form submissions.
```

### Raw side-by-side (no synthesis)

```
Use the broker with synthesize=false to compare how Claude and Codex would
approach rate-limiting a REST API endpoint.
```

### All three AIs

```
Use the broker with targets ["claude", "codex", "perplexity"] to research
the current best MCP servers for browser automation and give me a recommendation.
```

### Web-grounded research

```
Ask Perplexity what the latest WordPress security patches cover and whether
any affect the WooCommerce REST API.
```

### Role-scoped review

```
Ask Claude to review /Users/you/project/login.php as a security expert
looking specifically for SQL injection and authentication bypass vulnerabilities
```

---

## Testing your setup

```bash
node ~/.modelmux/src/test.js
```

This checks:
- Connectivity to each configured API (Claude, OpenAI, Perplexity)
- Local file read/write access

Run it any time you want to verify your keys are working or after moving to a new machine.

---

## Cost

modelmux calls bypass your Claude Code and Codex subscription quotas entirely. Each call is billed at standard API rates against your API accounts:

| Usage pattern | Estimated monthly cost |
|---|---|
| A few text cross-reviews per day | ~$2–5 across all APIs |
| Broker calls several times per day | ~$10–20 |
| Heavy all-day usage | Could exceed $40 |

**File calls cost more than text-only calls.** Images and PDFs are base64-encoded before being sent, which significantly increases token count. A one-page PDF or a medium-resolution image can use 10–50x the tokens of a plain text prompt. Use file-based calls when you genuinely need the AI to see the file; paste code as text when that's sufficient.

The `broker` tool with `synthesize=true` makes two Claude calls per invocation (one for the query, one for synthesis). Use `ask_claude` or `ask_codex` individually when you only need one opinion.

You need a small amount of credit loaded on each API account — even $5 on each lasts a long time at light usage. These are separate from your claude.ai and ChatGPT subscriptions:
- **Anthropic Console:** console.anthropic.com
- **OpenAI Platform:** platform.openai.com

---

## File layout

```
modelmux/
├── install.sh          ← run this on each Mac
├── package.json
├── package-lock.json
├── README.md
├── CLAUDE.md           ← guidance for AI coding agents working on the repo
├── LICENSE             ← Apache-2.0
├── NOTICE              ← attribution notice (Apache-2.0)
├── .gitignore
└── src/
    ├── server.js       ← the MCP server (stdio transport, no dependencies)
    └── test.js         ← API connectivity smoke test
```

`server.js` has no npm dependencies — it uses only Node.js built-ins and the native `fetch` API (available since Node 18). No `npm install` needed.

---

## Troubleshooting

**Tools don't appear in Claude Code or Codex**
Restart the app after registration. MCP servers are loaded at startup — and for the Desktop app you must fully quit it (Cmd+Q), not just close the window.

**Nothing shows up under MCP servers in the Claude Desktop app**
The installer's auto-registration only runs if it can find a `claude` command. The Desktop app has no `claude` on your PATH, so on older installs the step was skipped. Re-run `bash install.sh` (it now detects the app's bundled binary), or register manually using the **Claude Desktop app** commands under [Manual registration](#manual-registration-if-the-installer-skipped-a-tool). Note it registers at **user** scope, so it appears as a *user* server (available everywhere), not a *local* one.

**"X_API_KEY not set" error**
In a **terminal**-launched tool, run `source ~/.zshrc` first (or open a fresh terminal). In the **Claude Desktop app**, exporting keys in `~/.zshrc` is not enough — the app doesn't read your shell profile. Register modelmux with the keys passed as `-e` env values (see [Manual registration](#manual-registration-if-the-installer-skipped-a-tool)); the installer does this for you.

**Connectivity test fails**
Check that the key is correct and that your API account has credit loaded. Perplexity requires a paid API plan (separate from Perplexity Pro).

**Registered but getting no response**
Run `claude mcp list` or `codex mcp list` to confirm `modelmux` appears. If it does, try the test script to isolate which API is failing.

**"File not found" error**
Use an absolute path (starting with `/`) rather than a relative path. In Claude Code or Codex sessions the working directory may not be where you expect. Example: `/Users/you/project/auth.php` rather than `./auth.php`.

**"File too large" error**
The 20 MB limit applies to the raw file size before base64 encoding. For large PDFs, consider splitting them or copying the relevant pages to a new file first.

**Image or PDF not being understood by the AI**
Confirm the file extension is one of the supported types. If you're using a `.jpeg` extension it will work — both `.jpg` and `.jpeg` are recognised. For PDFs, very large or scanned-only documents (no embedded text layer) may produce poor results.

**Perplexity says it can't see my image/PDF**
This is expected — Perplexity's API does not support vision or document inputs. The broker sends Perplexity a text note explaining the file was skipped. Use `ask_claude` or `ask_codex` directly for image and PDF analysis.

**Want to unregister**
```bash
claude mcp remove modelmux
codex mcp remove modelmux
rm -rf ~/.modelmux
```
Then remove the API key exports from `~/.zshrc` if desired.

---

## Contributing

Pull requests welcome. The server is intentionally minimal — a single file with no npm dependencies. Keep it that way if you can. Contributions are accepted under the Apache-2.0 license (per section 5 of the license).

If you add support for a new file type or AI provider, update the file support matrix in this README and add a test case to `src/test.js`.

---

## Author

Jason R. Woodcock

---

## License

Licensed under the **Apache License, Version 2.0**.
Copyright © 2026 Jason R. Woodcock.

You are free to use, modify, and redistribute this software, including for
commercial purposes. In return, the license requires that you:

- retain the copyright, license, and attribution notices (see [NOTICE](NOTICE));
- state any significant changes you make to the files; and
- include a copy of the license with any redistribution.

It also includes an explicit patent grant from contributors. See the
[LICENSE](LICENSE) and [NOTICE](NOTICE) files for the full terms.
