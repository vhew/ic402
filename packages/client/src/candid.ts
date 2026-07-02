/// Shared decoders for agent-js Candid shapes.
///
/// agent-js decodes Candid `opt T` as `[] | [T]` and `vec nat8`/`blob` as a `Uint8Array`, a
/// `number[]`, or (rarely) an index-keyed object. These helpers centralize the unwrapping so every
/// call site handles the shapes identically — the logic was previously re-inlined ~8 times with
/// subtle divergences (some sites dropped the empty-array check, silently treating a `[]` opt as a
/// truthy value instead of "none").

/** Unwrap a Candid `opt`/`vec` decode (`[] | [T]` or `T[]`) to its first element, or `undefined`
 *  when empty. Tolerates a bare (non-array) value for mocked/legacy shapes. */
export function unwrapOpt<T>(x: unknown): T | undefined {
  if (Array.isArray(x)) return x.length > 0 ? (x[0] as T) : undefined;
  return (x ?? undefined) as T | undefined;
}

/** Unwrap a Candid `opt nat` to a bigint, or `fallback` when absent. Accepts bigint/number/string
 *  element shapes. */
export function unwrapOptNat(x: unknown, fallback: bigint): bigint {
  const v = unwrapOpt<bigint | number | string>(x);
  if (v === undefined || v === null) return fallback;
  return typeof v === 'bigint' ? v : BigInt(v);
}

/** Normalize a Candid `vec nat8` decode (Uint8Array | number[] | index-keyed object) to number[]. */
export function toByteArray(raw: unknown): number[] {
  if (raw instanceof Uint8Array) return Array.from(raw);
  if (Array.isArray(raw)) return raw as number[];
  return Object.values(raw as Record<string, number>);
}

/** Normalize a Candid `blob` decode to a Uint8Array. */
export function toBytes(raw: unknown): Uint8Array {
  return raw instanceof Uint8Array ? raw : new Uint8Array(raw as ArrayLike<number>);
}
