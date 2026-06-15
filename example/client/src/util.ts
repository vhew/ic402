import type { Client } from '@modelcontextprotocol/sdk/client/index.js';

/** Call an MCP tool and return the parsed JSON result (or raw text). */
export async function mcpCall(
  client: Client,
  tool: string,
  args: Record<string, unknown> = {},
  timeoutMs?: number,
): Promise<unknown> {
  const options = timeoutMs ? { timeout: timeoutMs } : undefined;
  const res = await client.callTool({ name: tool, arguments: args }, undefined, options);
  const text =
    res.content && Array.isArray(res.content) && res.content.length > 0
      ? ((res.content[0] as { text?: string }).text ?? '')
      : '';
  if (res.isError) {
    throw new Error(text || `MCP tool ${tool} failed`);
  }
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

/**
 * C6: Detect an MCP error envelope. The MCP's admin/signing tools (uploadContent,
 * submit_job_result, claim_job, sign_typed_data, …) return failures as a NON-isError
 * result whose JSON is `{status:'error', …}` or a Candid `{err: …}`/`{error: …}` — so
 * `mcpCall` does NOT throw for them. Steps that printed `success(...)` unconditionally
 * after such a call reported a green "payment settled" even when the canister rejected
 * the job. Use this (via assertMcpOk) to gate success on the actual canister verdict.
 */
export function isMcpErrorEnvelope(value: unknown): boolean {
  if (value == null || typeof value !== 'object') return false;
  const v = value as Record<string, unknown>;
  if (v.status === 'ok' || v.status === 'free') return false;
  if (v.status === 'error') return true;
  if ('err' in v) return true;
  if ('error' in v) return true;
  return false;
}

/** Best-effort human-readable message from an MCP error envelope. */
export function mcpErrorMessage(value: unknown): string {
  if (value && typeof value === 'object') {
    const v = value as Record<string, unknown>;
    const err = v.error ?? v.err;
    if (typeof err === 'string') return err;
    if (err && typeof err === 'object' && 'message' in (err as Record<string, unknown>)) {
      return String((err as Record<string, unknown>).message);
    }
  }
  return 'MCP tool returned an error';
}

/** Throw if the MCP result is an error envelope — so a step cannot print success() over
 *  a canister-side failure (C6). */
export function assertMcpOk(value: unknown, action: string): void {
  if (isMcpErrorEnvelope(value)) {
    throw new Error(`${action} failed: ${mcpErrorMessage(value)}`);
  }
}

/** Pretty-print a JSON value with 2-space indent. */
export function formatJson(value: unknown): string {
  return JSON.stringify(value, null, 2);
}

const CYAN = '\x1b[36m';
const GREEN = '\x1b[32m';
const YELLOW = '\x1b[33m';
const RED = '\x1b[31m';
const DIM = '\x1b[2m';
const BOLD = '\x1b[1m';
const RESET = '\x1b[0m';

export function header(text: string): void {
  // Push previous content up (scrollable) rather than erasing it
  const rows = process.stdout.rows || 40;
  console.log('\n'.repeat(rows));
  // Move cursor to top of the visible area
  process.stdout.write(`\x1b[${rows}A`);
  console.log(`\n${BOLD}${CYAN}${'═'.repeat(60)}${RESET}`);
  console.log(`${BOLD}${CYAN}  ${text}${RESET}`);
  console.log(`${BOLD}${CYAN}${'═'.repeat(60)}${RESET}\n`);
}

export function info(text: string): void {
  console.log(`${DIM}  ${text}${RESET}`);
}

export function success(text: string): void {
  console.log(`${GREEN}  ✓ ${text}${RESET}`);
}

export function warn(text: string): void {
  console.log(`${YELLOW}  ⚠ ${text}${RESET}`);
}

export function error(text: string): void {
  console.log(`${RED}  ✗ ${text}${RESET}`);
}

export function result(value: unknown): void {
  const json = formatJson(value);
  for (const line of json.split('\n')) {
    console.log(`  ${line}`);
  }
}

/** Bold highlighted text for innovation callouts visible to judges. */
export function highlight(text: string): void {
  console.log(`${BOLD}${YELLOW}  → ${text}${RESET}`);
}

/** Show a key-value state line (cyan key, white value). */
export function state(key: string, value: string): void {
  console.log(`  ${CYAN}${key}:${RESET} ${value}`);
}

/** Horizontal divider. */
export function divider(): void {
  console.log(`${DIM}  ${'─'.repeat(56)}${RESET}`);
}

/** Compact "what's different" comparison block. */
export function versus(x402: string[], ic402: string[]): void {
  console.log(`${DIM}  WHAT'S DIFFERENT:${RESET}`);
  console.log(`${DIM}  x402  │ ${x402[0]}${RESET}`);
  for (let i = 1; i < x402.length; i++) console.log(`${DIM}       │ ${x402[i]}${RESET}`);
  console.log(`${BOLD}  ic402 │ ${ic402[0]}${RESET}`);
  for (let i = 1; i < ic402.length; i++) console.log(`${BOLD}       │ ${ic402[i]}${RESET}`);
}

/** Labeled section header within a step — lighter than header(). */
export function section(text: string): void {
  console.log(`\n  ${BOLD}${text}${RESET}`);
}

/**
 * Display an image inline in the terminal.
 * Uses the iTerm2 inline image protocol (also supported by WezTerm, Hyper, etc).
 * Falls back to a text description on unsupported terminals.
 */
export function showImage(data: Buffer, name: string): void {
  // Check if running in a terminal that supports inline images.
  // TERM_PROGRAM may not be inherited through pnpm, so also check
  // common indicators and fall back to trying anyway on macOS iTerm.
  const term = process.env.TERM_PROGRAM ?? process.env.LC_TERMINAL ?? '';
  const supported =
    term.includes('iTerm') || term === 'WezTerm' || process.env.ITERM_SESSION_ID != null;

  if (supported) {
    const b64 = data.toString('base64');
    const nameB64 = Buffer.from(name).toString('base64');
    // Use \x1b\\ (ST) terminator — more compatible than \x07 (BEL)
    process.stdout.write(
      `  \x1b]1337;File=name=${nameB64};size=${data.length};inline=1;width=30:${b64}\x1b\\\n`,
    );
  } else {
    info(`[Image: ${name}, ${data.length} bytes]`);
  }
}
