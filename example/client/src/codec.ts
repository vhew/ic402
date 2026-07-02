/**
 * Small decode/format helpers shared across the demo steps. These normalize the
 * handful of shapes the canister's Candid interface (via agent-js) and the MCP
 * `call` tool render values in, so each step doesn't re-derive the same unwrap.
 */

/**
 * Candid `opt` decodes (through agent-js) as `[]` (none) or `[value]` (some); a
 * bare non-array value is also tolerated. Returns the unwrapped value, or
 * `undefined` when absent.
 */
export function unwrapOpt<T = unknown>(raw: unknown): T | undefined {
  if (Array.isArray(raw)) return raw.length > 0 ? (raw[0] as T) : undefined;
  return raw == null ? undefined : (raw as T);
}

/**
 * Normalize an optional Candid `?Text` (e.g. `settlementTxHash`) into a printable
 * string, or `''` when absent/blank.
 */
export function optText(raw: unknown): string {
  const v = unwrapOpt(raw);
  return typeof v === 'string' && v ? v : '';
}

/**
 * Decode a payment nonce that may arrive as a Candid `vec nat8` (a `number[]`) OR,
 * when routed through the MCP `call` tool, as a HEX STRING — into the `number[]`
 * the canister expects. `Array.from(hexString)` would split it into hex
 * *characters* (`["4","8",…]`) which Candid rejects ("Invalid vec nat8 … \"4\""),
 * so string inputs are hex-decoded.
 */
export function decodeNonce(raw: unknown): number[] {
  if (Array.isArray(raw)) return raw as number[];
  return Array.from(Buffer.from(String(raw ?? ''), 'hex'));
}

/**
 * Decode an inline content blob that may be a hex string or a Candid `vec nat8`
 * (a `number[]`) into a Buffer. Returns an empty Buffer for anything else.
 */
export function decodeInlineBlob(inline: unknown): Buffer {
  if (typeof inline === 'string') return Buffer.from(inline, 'hex');
  if (Array.isArray(inline)) return Buffer.from(inline as number[]);
  return Buffer.alloc(0);
}

/** Format USDC atomic units (6 decimals) as a fixed-6 decimal string. */
export function formatUsdc(units: number | bigint): string {
  return (Number(units) / 1_000_000).toFixed(6);
}
