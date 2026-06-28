# CLAUDE.md

Guidance for Claude Code (and other agents) working in this repository.

## What this is

**modelmux** is an MCP (Model Context Protocol) server that lets Claude Code,
Codex, and Perplexity call each other as tools from within a terminal session.
Files (text, code, images, PDFs) can be attached by local path and are forwarded
to each AI in the appropriate API format. See [README.md](README.md) for the full
user-facing docs.

## Architecture

- **`src/server.js`** — the entire MCP server. Speaks JSON-RPC 2.0 over stdio
  (newline-delimited). Registers four tools:
  - `ask_claude` — Anthropic API
  - `ask_codex` — OpenAI API
  - `ask_perplexity` — Perplexity web-grounded search API
  - `broker` — fans out to multiple AIs in parallel, optionally synthesizes
- **`src/test.js`** — connectivity + file I/O smoke test (`npm test`).
- **`install.sh`** — per-machine installer: checks Node, copies files to
  `~/.modelmux/`, prompts for API keys (saved to `~/.zshrc`), and registers the
  server with Claude Code and Codex.

## Hard constraints — keep these intact

- **Zero npm dependencies.** The server uses only Node.js built-ins (`fs`,
  `path`, `readline`) and the native `fetch` API. Do **not** add packages or an
  `npm install` step. The empty `package-lock.json` reflects this — keep it that way.
- **Node.js 18+** required (for native `fetch`). Declared in `package.json` `engines`.
- **ESM** — `package.json` has `"type": "module"`; use `import`, not `require`.
- **stdio transport** — the server must never write anything but JSON-RPC to
  stdout. Use stderr for any diagnostics/logging.

## Configuration (environment variables)

- API keys: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `PERPLEXITY_API_KEY`
- Model overrides: `ANTHROPIC_MODEL`, `OPENAI_MODEL`, `PERPLEXITY_MODEL`

Never hardcode or commit keys. `.env` and `*.local` are gitignored.

## Commands

```bash
npm start    # run the server (node src/server.js) — normally launched by the MCP host
npm test     # connectivity + file I/O smoke test
bash install.sh   # install + register on a machine
```

## Conventions

- File-size limit for attachments: 20 MB (return a clear error past it).
- When adding a new file type or AI provider: update the file-support matrix in
  [README.md](README.md) and add a corresponding case to `src/test.js`.
- Match the existing heavily-commented, section-divider style in `server.js`.
- License: **Apache-2.0** (see [LICENSE](LICENSE) and [NOTICE](NOTICE)).
  `package.json` declares `"license": "Apache-2.0"`. Keep the `NOTICE` file and
  source-header license lines intact — they are the attribution mechanism. If you
  add new source files, carry an `@license Apache-2.0` header like the others.
