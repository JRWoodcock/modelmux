#!/usr/bin/env node
/**
 * @file test.js
 * @description modelmux — connectivity and file I/O smoke test
 *
 * Verifies that each configured API key is valid and reachable,
 * and that the Node.js process can read and write temporary files.
 * Run this after installation or any time you want to confirm
 * modelmux is ready to use.
 *
 * Usage:
 *   node ~/.modelmux/src/test.js
 *
 * Each check reports one of three outcomes:
 *   PASS  — the check succeeded
 *   SKIP  — the relevant API key is not set; the check was not attempted
 *   FAIL  — the check ran but produced an unexpected result or error
 *
 * @author  Jason R. Woodcock
 * @version 2.0.1
 * @license Apache-2.0 — see the LICENSE and NOTICE files.
 */

import { writeFileSync, readFileSync, unlinkSync } from "fs";

// A minimal prompt that should produce a short, deterministic response.
// This is used for all three API connectivity checks.
const PING_PROMPT = "Reply with exactly: OK";

// ---------------------------------------------------------------------------
// API connectivity checks
// ---------------------------------------------------------------------------

/**
 * Checks that the Anthropic API key is valid by sending a minimal message.
 *
 * @returns {Promise<string>} A PASS, SKIP, or FAIL result string.
 */
async function testClaude() {
  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) return "SKIP (ANTHROPIC_API_KEY not set)";

  try {
    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type":      "application/json",
        "x-api-key":         key,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model:      process.env.ANTHROPIC_MODEL || "claude-sonnet-4-6",
        max_tokens: 16,
        messages:   [{ role: "user", content: PING_PROMPT }],
      }),
    });

    if (!response.ok) {
      return `FAIL (HTTP ${response.status}: ${await response.text()})`;
    }

    const data  = await response.json();
    const reply = data.content?.[0]?.text?.trim();
    return `PASS — received "${reply}"`;
  } catch (err) {
    return `FAIL (${err.message})`;
  }
}

/**
 * Checks that the OpenAI API key is valid by sending a minimal message.
 *
 * @returns {Promise<string>} A PASS, SKIP, or FAIL result string.
 */
async function testOpenAI() {
  const key = process.env.OPENAI_API_KEY;
  if (!key) return "SKIP (OPENAI_API_KEY not set)";

  try {
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization:  `Bearer ${key}`,
      },
      body: JSON.stringify({
        model:      process.env.OPENAI_MODEL || "gpt-4o",
        max_tokens: 16,
        messages:   [{ role: "user", content: PING_PROMPT }],
      }),
    });

    if (!response.ok) {
      return `FAIL (HTTP ${response.status}: ${await response.text()})`;
    }

    const data  = await response.json();
    const reply = data.choices?.[0]?.message?.content?.trim();
    return `PASS — received "${reply}"`;
  } catch (err) {
    return `FAIL (${err.message})`;
  }
}

/**
 * Checks that the Perplexity API key is valid by sending a minimal message.
 *
 * @returns {Promise<string>} A PASS, SKIP, or FAIL result string.
 */
async function testPerplexity() {
  const key = process.env.PERPLEXITY_API_KEY;
  if (!key) return "SKIP (PERPLEXITY_API_KEY not set)";

  try {
    const response = await fetch("https://api.perplexity.ai/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization:  `Bearer ${key}`,
      },
      body: JSON.stringify({
        model:      process.env.PERPLEXITY_MODEL || "sonar-pro",
        max_tokens: 16,
        messages:   [{ role: "user", content: PING_PROMPT }],
      }),
    });

    if (!response.ok) {
      return `FAIL (HTTP ${response.status}: ${await response.text()})`;
    }

    const data  = await response.json();
    const reply = data.choices?.[0]?.message?.content?.trim();
    return `PASS — received "${reply}"`;
  } catch (err) {
    return `FAIL (${err.message})`;
  }
}

// ---------------------------------------------------------------------------
// File I/O check
// ---------------------------------------------------------------------------

/**
 * Verifies that the process can write a temporary file, read it back,
 * and clean up after itself. This confirms the file attachment feature
 * of modelmux will work correctly at runtime.
 *
 * @returns {string} A PASS or FAIL result string.
 */
function testFileIO() {
  const tmpPath = `/tmp/modelmux-io-test-${Date.now()}.js`;
  const content = 'console.log("modelmux file I/O test");';

  try {
    writeFileSync(tmpPath, content, "utf8");
    const readBack = readFileSync(tmpPath, "utf8");
    unlinkSync(tmpPath);

    if (!readBack.includes("modelmux file I/O test")) {
      return "FAIL (content mismatch after round-trip)";
    }
    return "PASS — temporary file written, read, and removed";
  } catch (err) {
    // Attempt cleanup even if the test itself failed.
    try { unlinkSync(tmpPath); } catch { /* already gone or never created */ }
    return `FAIL (${err.message})`;
  }
}

// ---------------------------------------------------------------------------
// Run all checks and report
// ---------------------------------------------------------------------------

console.log("modelmux — connectivity and file I/O check\n");

// Run all API checks concurrently to keep the total wait time short.
const [claude, openai, perplexity] = await Promise.all([
  testClaude(),
  testOpenAI(),
  testPerplexity(),
]);

// File I/O is synchronous and fast — run it after the async checks.
const fileIO = testFileIO();

console.log(`  Claude      → ${claude}`);
console.log(`  OpenAI      → ${openai}`);
console.log(`  Perplexity  → ${perplexity}`);
console.log(`  File I/O    → ${fileIO}`);
console.log("");

const allPassed = [claude, openai, perplexity, fileIO]
  .every((result) => result.startsWith("PASS") || result.startsWith("SKIP"));

if (allPassed) {
  console.log("✓ All checks passed. modelmux is ready to use.\n");
  console.log("  File types modelmux accepts by path:");
  console.log("    Claude and OpenAI  → code, text, images (.png .jpg .jpeg .gif .webp), PDFs");
  console.log("    Perplexity         → code and text files only\n");
  console.log("  Example prompts (use inside Claude Code or Codex):");
  console.log('    "Ask Claude to review /path/to/auth.php for security vulnerabilities"');
  console.log('    "Use the broker to analyse /path/to/diagram.png and suggest improvements"');
} else {
  console.log("✗ One or more checks failed. Review the output above and check your API keys.");
  process.exit(1);
}
