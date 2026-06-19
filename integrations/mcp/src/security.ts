/**
 * SSRF guard + redirect-safe outbound fetch for the ic402 MCP server.
 *
 * Extracted from index.ts so the (pure) URL/IP validation and the redirect-safe
 * fetch wrapper can be unit-tested without standing up the MCP server. The server
 * is driven by an LLM whose inputs may include untrusted web content while it
 * holds a controller identity, so every outbound fetch must refuse internal
 * targets AND re-validate each redirect hop — a validated origin that responds
 * 30x to http://169.254.169.254/ would otherwise reach cloud metadata (the SSRF
 * redirect-bypass, audit finding S2 / prior C2-H11).
 */

import { lookup as dnsLookup } from 'node:dns/promises';

export interface SsrfOptions {
  /** Allow http://localhost / 127.0.0.1 targets (local development only). */
  localDev: boolean;
}

export type FetchLike = (url: string, init?: RequestInit) => Promise<Response>;

/** Resolve a hostname to its IP addresses. Injectable for tests; defaults to node:dns. */
export type LookupLike = (hostname: string) => Promise<Array<{ address: string; family: number }>>;

export interface SafeFetchOptions extends SsrfOptions {
  /** Max redirect hops to follow, each re-validated. Default 5. */
  maxRedirects?: number;
  /** Injectable fetch (defaults to globalThis.fetch); used for testing. */
  fetchImpl?: FetchLike;
  /** Injectable DNS lookup (defaults to node:dns); used for testing. SEC-0 rebinding guard. */
  lookupImpl?: LookupLike;
}

/** Parse a dotted-quad IPv4 string to a 32-bit unsigned int, or null. */
export function ipv4ToInt(host: string): number | null {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return null;
  const parts = m.slice(1, 5).map((p) => Number(p));
  if (parts.some((p) => p > 255)) return null;
  return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0;
}

/** True if a literal IPv4 falls in a private/loopback/link-local/metadata range. */
export function isPrivateIpv4(host: string): boolean {
  const ip = ipv4ToInt(host);
  if (ip === null) return false;
  const inRange = (cidrBase: string, bits: number) => {
    const base = ipv4ToInt(cidrBase);
    if (base === null) return false;
    const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
    return (ip & mask) === (base & mask);
  };
  return (
    inRange('10.0.0.0', 8) ||
    inRange('172.16.0.0', 12) ||
    inRange('192.168.0.0', 16) ||
    inRange('127.0.0.0', 8) ||
    inRange('169.254.0.0', 16) || // link-local incl. 169.254.169.254 metadata
    inRange('100.64.0.0', 10) || // CGNAT (S23)
    inRange('0.0.0.0', 8)
  );
}

/**
 * Extract the embedded IPv4 from an IPv4-mapped IPv6 address (::ffff:…), in BOTH
 * the dotted form (::ffff:169.254.169.254) and the hex-compressed form
 * (::ffff:a9fe:a9fe) that `new URL()` normalizes it to. Without the hex case an
 * attacker reaches e.g. the cloud-metadata endpoint via http://[::ffff:169.254.169.254]/.
 */
export function extractMappedIpv4(h: string): string | null {
  const dotted = /^::ffff:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/.exec(h);
  if (dotted) return dotted[1];
  const hex = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(h);
  if (hex) {
    const hi = parseInt(hex[1], 16);
    const lo = parseInt(hex[2], 16);
    return `${(hi >> 8) & 0xff}.${hi & 0xff}.${(lo >> 8) & 0xff}.${lo & 0xff}`;
  }
  return null;
}

/** True if a host string is a loopback/link-local/ULA/metadata IPv6 literal. */
export function isPrivateIpv6(host: string): boolean {
  // URL hostnames keep IPv6 in brackets; strip them.
  let h = host;
  if (h.startsWith('[') && h.endsWith(']')) h = h.slice(1, -1);
  h = h.toLowerCase();
  if (h === '::1' || h === '::') return true;
  // Unique-local fc00::/7 → first byte 0xfc or 0xfd.
  if (h.startsWith('fc') || h.startsWith('fd')) return true;
  // Link-local fe80::/10.
  if (h.startsWith('fe8') || h.startsWith('fe9') || h.startsWith('fea') || h.startsWith('feb'))
    return true;
  // IPv4-mapped (::ffff:...) — extract the embedded IPv4 and re-check it.
  const embedded = extractMappedIpv4(h);
  if (embedded !== null && isPrivateIpv4(embedded)) return true;
  return false;
}

/**
 * Validate an outbound fetch URL against SSRF. Requires https: (or
 * http://localhost|127.0.0.1 when opts.localDev is set) and rejects hosts that
 * are literal/internal private, loopback, link-local, or metadata addresses,
 * plus obvious internal TLDs. Returns the parsed URL or throws.
 *
 * NOTE: this validates the LITERAL host only. DNS-rebinding (a public name that
 * resolves to a private IP) is handled by assertResolvedHostIsPublic(), which
 * safeFetch() calls for every hop before connecting.
 */
export function validateFetchUrl(raw: string, opts: SsrfOptions): URL {
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    throw new Error(`Invalid URL: ${raw}`);
  }
  const host = parsed.hostname.toLowerCase();
  const isLocalHost =
    host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '[::1]';

  if (parsed.protocol === 'http:') {
    if (!(opts.localDev && isLocalHost)) {
      throw new Error(
        `Refusing http:// URL (${raw}). Only https:// is allowed; ` +
          `http://localhost is permitted only when localDev is enabled via "configure".`,
      );
    }
    return parsed;
  }
  if (parsed.protocol !== 'https:') {
    throw new Error(`Refusing non-http(s) URL scheme "${parsed.protocol}" (${raw}).`);
  }

  // https path — still block internal targets unless explicitly local-dev'd.
  if (isLocalHost && !opts.localDev) {
    throw new Error(`Refusing localhost/loopback target (${raw}). Enable localDev to allow it.`);
  }
  if (isPrivateIpv4(host) && !opts.localDev) {
    throw new Error(`Refusing private/loopback/link-local/metadata IPv4 target (${raw}).`);
  }
  if (host === '169.254.169.254') {
    throw new Error(`Refusing cloud metadata endpoint (${raw}).`);
  }
  if (isPrivateIpv6(host) && !opts.localDev) {
    throw new Error(`Refusing private/loopback/link-local IPv6 target (${raw}).`);
  }
  if (host.endsWith('.local') || host.endsWith('.internal')) {
    throw new Error(`Refusing internal TLD host (${raw}).`);
  }
  return parsed;
}

/**
 * SEC-0: resolve a hostname and reject if ANY resolved address is private/loopback/link-local/
 * metadata — closes DNS-rebinding (a public name that resolves to an internal IP), which the
 * literal-host check in validateFetchUrl cannot catch. Literal IPs are already covered by
 * validateFetchUrl, so they short-circuit here. A narrow check-vs-connect rebind window remains
 * (the OS re-resolves at fetch time); fully closing it requires pinning the validated IP at the
 * connection layer (a custom undici dispatcher).
 */
export async function assertResolvedHostIsPublic(
  hostname: string,
  opts: SafeFetchOptions,
): Promise<void> {
  let h = hostname.toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.slice(1, -1);
  // Literal IPs were already validated by validateFetchUrl; resolving them adds nothing.
  if (ipv4ToInt(h) !== null || h.includes(':')) return;
  if (opts.localDev && (h === 'localhost' || h === '127.0.0.1' || h === '::1')) return;
  const doLookup: LookupLike =
    opts.lookupImpl ?? ((host) => dnsLookup(host, { all: true, verbatim: true }));
  let results: Array<{ address: string; family: number }>;
  try {
    results = await doLookup(h);
  } catch {
    throw new Error(`Refusing fetch: cannot resolve host "${hostname}".`);
  }
  for (const { address } of results) {
    if ((isPrivateIpv4(address) || isPrivateIpv6(address)) && !opts.localDev) {
      throw new Error(
        `Refusing fetch: host "${hostname}" resolves to a private/internal address (${address}) — DNS-rebinding blocked.`,
      );
    }
  }
}

/**
 * SSRF-safe fetch: validate the initial URL, then follow redirects MANUALLY,
 * re-validating every hop's Location before fetching it. This closes the
 * redirect-bypass where an allowlisted origin 30x's to an internal target.
 * SEC-0: each hop's host is also DNS-resolved and the resolved IPs re-checked
 * (assertResolvedHostIsPublic) so a public name can't rebind to an internal IP.
 * `fetchImpl` / `lookupImpl` are injectable for testing.
 */
export async function safeFetch(
  raw: string,
  init: RequestInit | undefined,
  opts: SafeFetchOptions,
): Promise<Response> {
  const fetchImpl = opts.fetchImpl ?? (globalThis.fetch as FetchLike);
  const maxRedirects = opts.maxRedirects ?? 5;
  let currentUrl = validateFetchUrl(raw, opts).toString();
  await assertResolvedHostIsPublic(new URL(currentUrl).hostname, opts);

  for (let hop = 0; hop <= maxRedirects; hop++) {
    const resp = await fetchImpl(currentUrl, { ...init, redirect: 'manual' });
    if (resp.status >= 300 && resp.status < 400) {
      const location = resp.headers.get('location');
      if (!location) return resp; // redirect with no target — hand back as-is
      const next = new URL(location, currentUrl).toString();
      // Re-validate the redirect target BEFORE following it (TOCTOU SSRF fix).
      currentUrl = validateFetchUrl(next, opts).toString();
      await assertResolvedHostIsPublic(new URL(currentUrl).hostname, opts);
      continue;
    }
    return resp;
  }
  throw new Error(`Refusing to follow more than ${maxRedirects} redirects (from ${raw}).`);
}
