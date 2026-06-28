#!/usr/bin/env node
/**
 * @file server.js
 * @description modelmux — Model Context Protocol (MCP) server
 *
 * Registers four tools that let Claude Code and Codex call each other,
 * and both call Perplexity, directly from within a terminal session.
 * Files (code, text, images, PDFs) can be attached by local path and
 * are forwarded to each AI using the appropriate API format.
 *
 * Tools provided:
 *   ask_claude      — query Anthropic's Claude API
 *   ask_codex       — query OpenAI's GPT API
 *   ask_perplexity  — query Perplexity's web-grounded search API
 *   broker          — query multiple AIs in parallel, then synthesize results
 *
 * File support:
 *   Text / code     → all three APIs (content inlined as a fenced block)
 *   Images          → Claude and OpenAI only (base64 vision format)
 *   PDFs            → Claude and OpenAI only (base64 document format)
 *   Perplexity      → text and code only; binary files receive a plain-text note
 *
 * Transport: stdio (newline-delimited JSON-RPC 2.0), as required by MCP.
 * No npm packages are required — only Node.js built-ins and the native fetch API.
 * Node.js 18 or higher is needed for fetch support.
 *
 * @author  Jason R. Woodcock
 * @version 2.0.0
 * @license Apache-2.0 — see the LICENSE and NOTICE files.
 */

import { readFileSync, existsSync, statSync } from "fs";
import { extname, resolve, basename } from "path";
import { createInterface } from "readline";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/**
 * Central configuration object built from environment variables.
 * All API keys and model names are read at startup so missing values
 * surface early rather than at the point of a tool call.
 *
 * Override any model by setting the corresponding environment variable
 * before launching Claude Code or Codex, e.g.:
 *   export ANTHROPIC_MODEL="claude-opus-4-6"
 */
const CONFIG = {
  anthropic: {
    apiKey:  process.env.ANTHROPIC_API_KEY,
    model:   process.env.ANTHROPIC_MODEL  || "claude-sonnet-4-6",
    baseUrl: "https://api.anthropic.com/v1/messages",
  },
  openai: {
    apiKey:  process.env.OPENAI_API_KEY,
    model:   process.env.OPENAI_MODEL    || "gpt-4o",
    baseUrl: "https://api.openai.com/v1/chat/completions",
  },
  perplexity: {
    apiKey:  process.env.PERPLEXITY_API_KEY,
    model:   process.env.PERPLEXITY_MODEL || "sonar-pro",
    baseUrl: "https://api.perplexity.ai/chat/completions",
  },
};

// ---------------------------------------------------------------------------
// File handling
// ---------------------------------------------------------------------------

/** Extensions treated as plain text and inlined into the prompt. */
const TEXT_EXTS = new Set([
  ".js", ".ts", ".jsx", ".tsx", ".mjs", ".cjs",
  ".py", ".rb", ".go", ".rs", ".java", ".kt", ".swift", ".c", ".cpp", ".h",
  ".php", ".html", ".css", ".scss", ".sql",
  ".json", ".yaml", ".yml", ".toml", ".env", ".ini", ".conf",
  ".md", ".txt", ".csv", ".xml", ".sh", ".bash", ".zsh",
]);

/** Extensions treated as images and sent via vision APIs. */
const IMAGE_EXTS = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp"]);

/** The only binary document type with direct API support across providers. */
const PDF_EXT = ".pdf";

/**
 * Maps file extensions to their canonical MIME types.
 * Used when building base64 payloads for vision and document API calls.
 */
const MIME_TYPES = {
  ".png":  "image/png",
  ".jpg":  "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif":  "image/gif",
  ".webp": "image/webp",
  ".pdf":  "application/pdf",
};

/**
 * Determines how a file should be handled based on its extension.
 *
 * @param {string} filePath - Path to the file (used only for extension lookup).
 * @returns {"text" | "image" | "pdf"} The handling category for this file.
 */
function fileType(filePath) {
  const ext = extname(filePath).toLowerCase();
  if (IMAGE_EXTS.has(ext)) return "image";
  if (ext === PDF_EXT)     return "pdf";
  // Everything else — including unknown extensions — is attempted as UTF-8 text.
  return "text";
}

/**
 * Reads a file from disk and returns a normalised descriptor object
 * that the AI caller functions can consume without further filesystem access.
 *
 * Text files are read as UTF-8 strings. Binary files (images, PDFs) are
 * read as Buffers and converted to base64 for API transmission.
 *
 * @param {string} filePath - Absolute or relative path to the file.
 * @returns {{ type: string, name: string, size: number, text?: string, base64?: string, mimeType?: string }}
 * @throws {Error} If the file does not exist or exceeds the 20 MB size limit.
 */
function loadFile(filePath) {
  const absolutePath = resolve(filePath);

  if (!existsSync(absolutePath)) {
    throw new Error(`File not found: ${absolutePath}`);
  }

  const stats   = statSync(absolutePath);
  const MAX_MB  = 20;
  const MAX_BYTES = MAX_MB * 1024 * 1024;

  if (stats.size > MAX_BYTES) {
    const sizeMB = (stats.size / 1024 / 1024).toFixed(1);
    throw new Error(`File too large (${sizeMB} MB). The limit is ${MAX_MB} MB.`);
  }

  const ext  = extname(absolutePath).toLowerCase();
  const type = fileType(absolutePath);
  const name = basename(absolutePath);

  if (type === "text") {
    const text = readFileSync(absolutePath, "utf8");
    // Guard against binary files with unrecognised extensions being inlined as
    // mojibake. Known text extensions are trusted as-is; for anything else, a
    // NUL byte is a reliable signal that the file is binary, not source text.
    if (!TEXT_EXTS.has(ext) && text.includes("\u0000")) {
      throw new Error(
        `"${name}" looks like a binary file (unrecognised extension "${ext || "none"}"). ` +
        `Supported types are code/text files, images (.png .jpg .jpeg .gif .webp), and PDFs.`
      );
    }
    return { type, name, size: stats.size, text };
  }

  // Binary file — encode as base64 for API transmission.
  const buffer   = readFileSync(absolutePath);
  const base64   = buffer.toString("base64");
  const mimeType = MIME_TYPES[ext] || "application/octet-stream";
  return { type, name, size: stats.size, base64, mimeType };
}

// ---------------------------------------------------------------------------
// MCP transport helpers
// ---------------------------------------------------------------------------

/**
 * Writes a JSON-RPC 2.0 response object to stdout.
 * MCP uses newline-delimited JSON over stdio, so each message ends with \n.
 *
 * @param {object} obj - A valid JSON-RPC 2.0 message object.
 */
function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

/**
 * Sends a JSON-RPC 2.0 error response for protocol-level failures
 * (e.g. unknown method). Tool execution errors are returned as
 * successful responses with isError: true, per MCP convention.
 *
 * @param {string|number|null} id      - The request ID from the client.
 * @param {number}             code    - A JSON-RPC error code.
 * @param {string}             message - Human-readable error description.
 */
function mcpError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

// ---------------------------------------------------------------------------
// AI caller: Claude (Anthropic)
// ---------------------------------------------------------------------------

/**
 * Sends a prompt — and optionally a file — to the Anthropic Messages API.
 *
 * The content format varies by file type:
 *   - No file:  plain string prompt.
 *   - Text:     single text block with the file inlined as a fenced code block.
 *   - Image:    image block followed by a text block (vision format).
 *   - PDF:      document block followed by a text block (document format).
 *
 * @param {string}      prompt       - The user's question or instruction.
 * @param {string}      [systemPrompt=""] - Optional system-level instruction.
 * @param {object|null} [file=null]  - File descriptor from loadFile(), or null.
 * @returns {Promise<string>} The text content of Claude's response.
 * @throws {Error} If the API key is missing or the API returns a non-2xx status.
 */
async function callClaude(prompt, systemPrompt = "", file = null) {
  const { apiKey, model, baseUrl } = CONFIG.anthropic;
  if (!apiKey) throw new Error("ANTHROPIC_API_KEY is not set in your environment.");

  // Build the content block(s) for the user message.
  let content;
  if (!file) {
    content = prompt;
  } else if (file.type === "text") {
    // Inline the file as a labelled fenced block so the model can reference it.
    content = [{
      type: "text",
      text: `${prompt}\n\n---\n**File: ${file.name}**\n\`\`\`\n${file.text}\n\`\`\``,
    }];
  } else if (file.type === "image") {
    // Vision format: image block first, then the text prompt.
    content = [
      { type: "image", source: { type: "base64", media_type: file.mimeType, data: file.base64 } },
      { type: "text", text: prompt },
    ];
  } else if (file.type === "pdf") {
    // Document format: PDF block first, then the text prompt.
    content = [
      { type: "document", source: { type: "base64", media_type: "application/pdf", data: file.base64 } },
      { type: "text", text: prompt },
    ];
  }

  const requestBody = { model, max_tokens: 4096, messages: [{ role: "user", content }] };
  if (systemPrompt) requestBody.system = systemPrompt;

  const response = await fetch(baseUrl, {
    method: "POST",
    headers: {
      "Content-Type":    "application/json",
      "x-api-key":       apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify(requestBody),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Anthropic API returned ${response.status}: ${body}`);
  }

  const data = await response.json();
  return data.content?.[0]?.text ?? "(no response)";
}

// ---------------------------------------------------------------------------
// AI caller: OpenAI (Codex / GPT)
// ---------------------------------------------------------------------------

/**
 * Sends a prompt — and optionally a file — to the OpenAI Chat Completions API.
 *
 * The user message content varies by file type:
 *   - No file:  plain string.
 *   - Text:     string with the file inlined as a fenced code block.
 *   - Image:    array with a text block and an image_url block (base64 data URI).
 *   - PDF:      array with a text block and a file block (base64 data URI).
 *
 * @param {string}      prompt            - The user's question or instruction.
 * @param {string}      [systemPrompt=""] - Optional system message prepended to the conversation.
 * @param {object|null} [file=null]       - File descriptor from loadFile(), or null.
 * @returns {Promise<string>} The text content of the model's response.
 * @throws {Error} If the API key is missing or the API returns a non-2xx status.
 */
async function callOpenAI(prompt, systemPrompt = "", file = null) {
  const { apiKey, model, baseUrl } = CONFIG.openai;
  if (!apiKey) throw new Error("OPENAI_API_KEY is not set in your environment.");

  const messages = [];
  if (systemPrompt) messages.push({ role: "system", content: systemPrompt });

  let userContent;
  if (!file) {
    userContent = prompt;
  } else if (file.type === "text") {
    userContent = `${prompt}\n\n---\n**File: ${file.name}**\n\`\`\`\n${file.text}\n\`\`\``;
  } else if (file.type === "image") {
    // OpenAI vision format: text and image_url blocks in an array.
    userContent = [
      { type: "text",      text: prompt },
      { type: "image_url", image_url: { url: `data:${file.mimeType};base64,${file.base64}` } },
    ];
  } else if (file.type === "pdf") {
    // GPT-4o accepts PDFs as inline base64 file blocks.
    userContent = [
      { type: "text", text: prompt },
      { type: "file", file: { filename: file.name, file_data: `data:application/pdf;base64,${file.base64}` } },
    ];
  }

  messages.push({ role: "user", content: userContent });

  const response = await fetch(baseUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
    body: JSON.stringify({ model, messages, max_tokens: 4096 }),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`OpenAI API returned ${response.status}: ${body}`);
  }

  const data = await response.json();
  return data.choices?.[0]?.message?.content ?? "(no response)";
}

// ---------------------------------------------------------------------------
// AI caller: Perplexity
// ---------------------------------------------------------------------------

/**
 * Sends a prompt — and optionally a text file — to the Perplexity Chat API.
 *
 * Perplexity does not offer a vision or document API. When a binary file
 * (image or PDF) is supplied, a plain-text note is appended to the prompt
 * explaining that the file was not forwarded, so the model can still
 * provide a useful response rather than receiving an unexpected request.
 *
 * @param {string}      prompt            - The user's question or research query.
 * @param {string}      [systemPrompt=""] - Optional system message.
 * @param {object|null} [file=null]       - File descriptor from loadFile(), or null.
 * @returns {Promise<string>} The text content of Perplexity's response.
 * @throws {Error} If the API key is missing or the API returns a non-2xx status.
 */
async function callPerplexity(prompt, systemPrompt = "", file = null) {
  const { apiKey, model, baseUrl } = CONFIG.perplexity;
  if (!apiKey) throw new Error("PERPLEXITY_API_KEY is not set in your environment.");

  let fullPrompt = prompt;

  if (file) {
    if (file.type === "text") {
      // Text and code files can be inlined just like the other providers.
      fullPrompt = `${prompt}\n\n---\n**File: ${file.name}**\n\`\`\`\n${file.text}\n\`\`\``;
    } else {
      // Binary file — notify the model rather than sending an incompatible payload.
      fullPrompt =
        `${prompt}\n\n---\n` +
        `Note: A ${file.type} file named "${file.name}" was attached to this request, ` +
        `but this API does not support vision or document inputs. ` +
        `Please answer based on the text prompt alone, or describe what you would ` +
        `look for in a file of this type if you were able to inspect it.`;
    }
  }

  const messages = [];
  if (systemPrompt) messages.push({ role: "system", content: systemPrompt });
  messages.push({ role: "user", content: fullPrompt });

  const response = await fetch(baseUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
    body: JSON.stringify({ model, messages, max_tokens: 4096 }),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Perplexity API returned ${response.status}: ${body}`);
  }

  const data = await response.json();
  return data.choices?.[0]?.message?.content ?? "(no response)";
}

// ---------------------------------------------------------------------------
// MCP tool definitions
// ---------------------------------------------------------------------------

/**
 * Shared schema fragment for the optional file parameter.
 * Spread into each tool's inputSchema.properties to avoid repetition.
 */
const FILE_PARAM = {
  file: {
    type: "string",
    description:
      "Optional path to a local file. Absolute paths are recommended to avoid " +
      "ambiguity about the working directory. " +
      "Supported types: code and text files (.js .ts .php .py .md .json etc.), " +
      "images (.png .jpg .jpeg .gif .webp), and PDFs (.pdf). " +
      "Example: /Users/you/project/auth.php",
  },
};

/**
 * The four tools exposed to MCP clients (Claude Code, Codex, etc.).
 * Each entry follows the MCP tool schema: name, description, and inputSchema.
 * The descriptions are written so the host agent can decide when to call each tool
 * without additional instruction.
 */
const TOOLS = [
  {
    name: "ask_claude",
    description:
      "Send a prompt to Claude (Anthropic). Optionally attach a local file — " +
      "code, text, image, or PDF — for Claude to read and include in its analysis. " +
      "Use this when you want Claude's perspective on a question, piece of code, " +
      "document, or design.",
    inputSchema: {
      type: "object",
      properties: {
        prompt: { type: "string", description: "The question or instruction for Claude." },
        system: { type: "string", description: "Optional system prompt that sets Claude's role, e.g. 'You are a security auditor'." },
        ...FILE_PARAM,
      },
      required: ["prompt"],
    },
  },
  {
    name: "ask_codex",
    description:
      "Send a prompt to OpenAI (GPT-4o by default). Optionally attach a local file. " +
      "Use this when you want a second opinion on code, an alternative implementation, " +
      "or OpenAI's perspective on an architecture or design decision.",
    inputSchema: {
      type: "object",
      properties: {
        prompt: { type: "string", description: "The question or instruction for OpenAI." },
        system: { type: "string", description: "Optional system prompt." },
        ...FILE_PARAM,
      },
      required: ["prompt"],
    },
  },
  {
    name: "ask_perplexity",
    description:
      "Send a research question to Perplexity for a web-grounded answer with citations. " +
      "Text and code files can be attached. Images and PDFs cannot (Perplexity has no vision API). " +
      "Use this for current information, documentation lookups, or questions that benefit " +
      "from live web search.",
    inputSchema: {
      type: "object",
      properties: {
        prompt: { type: "string", description: "The research question for Perplexity." },
        system: { type: "string", description: "Optional system prompt." },
        ...FILE_PARAM,
      },
      required: ["prompt"],
    },
  },
  {
    name: "broker",
    description:
      "Send a prompt to multiple AIs in parallel and receive a synthesized comparison. " +
      "Attach a file to have all selected AIs analyse the same document, image, or code. " +
      "Perplexity only receives text/code files; images and PDFs are forwarded to Claude " +
      "and OpenAI only. When synthesize is true (the default), Claude produces a final " +
      "summary identifying agreements, differences, and a recommended course of action.",
    inputSchema: {
      type: "object",
      properties: {
        prompt: {
          type: "string",
          description: "The question or instruction sent to all selected AIs.",
        },
        targets: {
          type: "array",
          items: { type: "string", enum: ["claude", "codex", "perplexity"] },
          description: "Which AIs to query. Defaults to ['claude', 'codex'] if omitted.",
        },
        system: {
          type: "string",
          description: "Optional system prompt applied to all targets.",
        },
        synthesize: {
          type: "boolean",
          description:
            "When true (default), Claude synthesizes all responses into one summary. " +
            "When false, each AI's raw response is returned side by side.",
        },
        ...FILE_PARAM,
      },
      required: ["prompt"],
    },
  },
];

// ---------------------------------------------------------------------------
// Tool handler
// ---------------------------------------------------------------------------

/**
 * Dispatches an incoming tool call to the appropriate AI caller function(s).
 *
 * Files are loaded once here and the resulting descriptor is passed to each
 * caller, avoiding repeated disk reads in parallel broker calls.
 *
 * @param {string} name - The tool name as registered in TOOLS.
 * @param {object} args - The arguments object from the MCP tool call.
 * @returns {Promise<string>} Markdown-formatted response text.
 * @throws {Error} For unknown tool names, missing API keys, or file load failures.
 */
async function handleTool(name, args) {
  // Load the file once, if one was provided, so all parallel callers share it.
  const file   = args.file ? loadFile(args.file) : null;
  const system = args.system || "";

  switch (name) {

    case "ask_claude":
      return await callClaude(args.prompt, system, file);

    case "ask_codex":
      return await callOpenAI(args.prompt, system, file);

    case "ask_perplexity":
      return await callPerplexity(args.prompt, system, file);

    case "broker": {
      const targets    = args.targets  || ["claude", "codex"];
      const synthesize = args.synthesize !== false; // default true

      // Describe the attached file in the header if one was provided.
      const fileNote = file
        ? `\n📎 File: **${file.name}** (${file.type}, ${(file.size / 1024).toFixed(1)} KB)`
        : "";

      // Fire all target calls concurrently. Individual failures are captured
      // per-target rather than rejecting the entire broker call.
      const calls = targets.map(async (target) => {
        try {
          let response;
          if      (target === "claude")     response = await callClaude(args.prompt, system, file);
          else if (target === "codex")      response = await callOpenAI(args.prompt, system, file);
          else if (target === "perplexity") response = await callPerplexity(args.prompt, system, file);
          else                              response = `Unknown target: ${target}`;
          return { target, response, error: null };
        } catch (err) {
          return { target, response: null, error: err.message };
        }
      });

      const results = await Promise.all(calls);

      // Format each result as a headed section.
      const responseSections = results
        .map((r) =>
          r.error
            ? `### ${r.target.toUpperCase()}\n\n⚠️ Error: ${r.error}`
            : `### ${r.target.toUpperCase()}\n\n${r.response}`
        )
        .join("\n\n---\n\n");

      // Return raw responses side by side if synthesis was disabled.
      if (!synthesize) {
        return `# Broker Results${fileNote}\n\n${responseSections}`;
      }

      // Ask Claude to synthesize all responses into a single actionable summary.
      const synthesisPrompt =
        `You are synthesizing responses from multiple AI systems about the same question.\n\n` +
        `Original question:\n${args.prompt}\n` +
        (file ? `Attached file: ${file.name} (${file.type})\n` : "") +
        `\nResponses from each AI:\n${responseSections}\n\n` +
        `Please provide:\n` +
        `1. **Key agreements** — what all or most AIs agreed on\n` +
        `2. **Notable differences** — where they diverged and why it matters\n` +
        `3. **Recommended action** — the best path forward based on all input\n\n` +
        `Be concise and actionable.`;

      // Synthesis is performed by Claude. If it fails — most commonly because
      // no Anthropic key is set when Claude was not itself a target — fall back
      // to the raw side-by-side responses rather than discarding work already done.
      let synthesis;
      try {
        synthesis = await callClaude(synthesisPrompt);
      } catch (err) {
        return (
          `# Broker Results${fileNote}\n\n` +
          `_Synthesis was skipped: ${err.message}_\n\n` +
          `${responseSections}`
        );
      }

      return (
        `# Broker Synthesis${fileNote}\n\n` +
        `${synthesis}\n\n` +
        `---\n\n` +
        `# Raw Responses\n\n` +
        `${responseSections}`
      );
    }

    default:
      throw new Error(`Unknown tool name: "${name}"`);
  }
}

// ---------------------------------------------------------------------------
// MCP message loop
// ---------------------------------------------------------------------------

/**
 * Reads newline-delimited JSON-RPC 2.0 messages from stdin and dispatches them.
 *
 * Handled methods:
 *   initialize            — capability handshake required by all MCP clients
 *   notifications/initialized — acknowledgement from the client (no reply needed)
 *   tools/list            — returns the TOOLS array
 *   tools/call            — executes a tool and returns the result
 *
 * Any unrecognised method receives a JSON-RPC -32601 (Method Not Found) error.
 * Non-JSON lines (e.g. blank lines or debug output) are silently ignored.
 */
const rl = createInterface({ input: process.stdin, terminal: false });

rl.on("line", async (line) => {
  // Ignore blank or non-JSON lines without crashing.
  let message;
  try {
    message = JSON.parse(line.trim());
  } catch {
    return;
  }

  const { id, method, params } = message;

  // Capability handshake — the client sends this first before any tool calls.
  if (method === "initialize") {
    send({
      jsonrpc: "2.0",
      id,
      result: {
        protocolVersion: "2024-11-05",
        serverInfo: { name: "modelmux", version: "2.0.0" },
        capabilities: { tools: {} },
      },
    });
    return;
  }

  // Client acknowledgement — no response required by the MCP spec.
  if (method === "notifications/initialized") return;

  // Return the list of available tools so the client can discover them.
  if (method === "tools/list") {
    send({ jsonrpc: "2.0", id, result: { tools: TOOLS } });
    return;
  }

  // Execute the requested tool and return its output.
  if (method === "tools/call") {
    const toolName = params?.name;
    const toolArgs = params?.arguments ?? {};
    try {
      const result = await handleTool(toolName, toolArgs);
      send({
        jsonrpc: "2.0",
        id,
        result: { content: [{ type: "text", text: result }] },
      });
    } catch (err) {
      // Tool errors are returned as successful MCP responses with isError: true,
      // so the host agent can surface the message to the user in context.
      send({
        jsonrpc: "2.0",
        id,
        result: {
          content: [{ type: "text", text: `Error: ${err.message}` }],
          isError: true,
        },
      });
    }
    return;
  }

  // Anything else is an unsupported protocol method.
  mcpError(id, -32601, `Method not found: ${method}`);
});
