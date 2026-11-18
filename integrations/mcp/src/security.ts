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
    inRange('0.0.0.0', 8) ||
    inRange('198.18.0.0', 15) || // benchmarking (RFC 2544), routable on some internal networks
    inRange('240.0.0.0', 4) // reserved, incl. broadcast 255.255.255.255
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

/**
 * Parse an IPv6 literal (brackets and a zone id allowed, a trailing dotted IPv4 allowed) into its
 * eight 16-bit groups, or null when the string is not an IPv6 literal. A hostname such as
 * `fda.gov` has no colon, so it is never read as an address.
 */
export function parseIpv6(host: string): number[] | null {
  let h = host.toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.slice(1, -1);
  const zone = h.indexOf('%');
  if (zone >= 0) h = h.slice(0, zone);
  if (!h.includes(':')) return null;
  const lastColon = h.lastIndexOf(':');
  const tail = h.slice(lastColon + 1);
  if (tail.includes('.')) {
    const v4 = ipv4ToInt(tail);
    if (v4 === null) return null;
    h = `${h.slice(0, lastColon + 1)}${(v4 >>> 16).toString(16)}:${(v4 & 0xffff).toString(16)}`;
  }
  const halves = h.split('::');
  if (halves.length > 2) return null;
  const groups = (s: string): number[] =>
    s === '' ? [] : s.split(':').map((g) => (/^[0-9a-f]{1,4}$/.test(g) ? parseInt(g, 16) : NaN));
  const head = groups(halves[0]);
  const rest = halves.length === 2 ? groups(halves[1]) : [];
  if ([...head, ...rest].some(Number.isNaN)) return null;
  if (halves.length === 1) return head.length === 8 ? head : null;
  const fill = 8 - head.length - rest.length;
  if (fill < 1) return null;
  return [...head, ...new Array<number>(fill).fill(0), ...rest];
}

/** True if a host string is a loopback/link-local/ULA/metadata IPv6 literal, or an IPv6 form
 *  that embeds a private IPv4 (IPv4-mapped ::ffff:0:0/96, NAT64 64:ff9b::/96, 6to4 2002::/16). */
export function isPrivateIpv6(host: string): boolean {
  const g = parseIpv6(host);
  if (g === null) return false; // a hostname, not an IPv6 literal
  const v4 = (hi: number, lo: number) => `${hi >> 8}.${hi & 0xff}.${lo >> 8}.${lo & 0xff}`;
  const zeroUpTo = (n: number) => g.slice(0, n).every((x) => x === 0);
  if (zeroUpTo(7) && (g[7] === 0 || g[7] === 1)) return true; // :: and ::1
  if ((g[0] & 0xfe00) === 0xfc00) return true; // unique-local fc00::/7
  if ((g[0] & 0xffc0) === 0xfe80) return true; // link-local fe80::/10
  if (zeroUpTo(5) && g[5] === 0xffff) return isPrivateIpv4(v4(g[6], g[7])); // ::ffff:a.b.c.d
  if (g[0] === 0x64 && g[1] === 0xff9b && g[2] === 0 && g[3] === 0 && g[4] === 0 && g[5] === 0)
    return isPrivateIpv4(v4(g[6], g[7])); // NAT64 (RFC 6052): a gateway forwards to the IPv4
  if (g[0] === 0x2002) return isPrivateIpv4(v4(g[1], g[2])); // 6to4 (RFC 3056)
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

/** 2.22.0 (I11): the most bytes the MCP reads from any fetched body (probe, paid response, content). */
export const MAX_FETCH_BODY_BYTES = 10 * 1024 * 1024;

/** Read a response body as UTF-8 text, refusing (and cancelling) a body over `maxBytes`. */
export async function readTextCapped(
  resp: Response,
  maxBytes: number = MAX_FETCH_BODY_BYTES,
): Promise<string> {
  const declared = resp.headers.get('content-length');
  if (declared !== null && /^\d+$/.test(declared) && BigInt(declared) > BigInt(maxBytes)) {
    await resp.body?.cancel().catch(() => {});
    throw new Error(`Refusing a ${declared}-byte response body (limit ${maxBytes} bytes).`);
  }
  if (!resp.body) return '';
  const reader = resp.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => {});
      throw new Error(`Refusing a response body over the ${maxBytes}-byte limit.`);
    }
    chunks.push(value);
  }
  return new TextDecoder().decode(Buffer.concat(chunks));
}

/**
 * 2.22.0 (I11): the HTTP half of the fetch_x402 probe. Goes through safeFetch, so the URL and
 * EVERY redirect hop get the literal-host and the DNS check, and reads at most
 * MAX_FETCH_BODY_BYTES. A 402 returns its payment JSON (the base64 `payment-required` header, else
 * the body); any other status returns the body.
 */
export async function probeChallenge(
  raw: string,
  init: RequestInit | undefined,
  opts: SafeFetchOptions,
): Promise<{ status: number; ok: boolean; body: string; paymentJson?: string }> {
  const resp = await safeFetch(raw, init, opts);
  if (resp.status !== 402) {
    return { status: resp.status, ok: resp.ok, body: await readTextCapped(resp) };
  }
  let paymentJson = '';
  const header = resp.headers.get('payment-required');
  if (header) {
    try {
      paymentJson = atob(header);
    } catch {
      paymentJson = header;
    }
  }
  if (!paymentJson) paymentJson = await readTextCapped(resp);
  return { status: 402, ok: false, body: '', paymentJson };
}

/**
 * 2.22.0 (I8): fetch the replica's root key only for local development against an EXACT local
 * host — `localhost`, `127.0.0.1` or `[::1]`, any port. A substring test trusted
 * `https://localhost.evil.example`; a fetched root key lets that host forge every response.
 */
export function shouldFetchRootKey(host: string, localDev: boolean): boolean {
  if (!localDev) return false;
  let u: URL;
  try {
    u = new URL(host);
  } catch {
    return false;
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return false;
  const h = u.hostname.toLowerCase();
  return h === 'localhost' || h === '127.0.0.1' || h === '[::1]';
}
