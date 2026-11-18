import { describe, it, expect } from 'vitest';
import {
  validateFetchUrl,
  safeFetch,
  assertResolvedHostIsPublic,
  isPrivateIpv6,
  probeChallenge,
  sendPaidRequest,
  readTextCapped,
  shouldFetchRootKey,
} from '../integrations/mcp/src/security';

const PROD = { localDev: false };

describe('MCP SSRF: validateFetchUrl', () => {
  it('allows a normal https URL', () => {
    expect(validateFetchUrl('https://example.com/data', PROD).host).toBe('example.com');
  });

  it('rejects plain http:// in production', () => {
    expect(() => validateFetchUrl('http://example.com/', PROD)).toThrow(/http:\/\//);
  });

  it('rejects non-http(s) schemes (file:, gopher:)', () => {
    expect(() => validateFetchUrl('file:///etc/passwd', PROD)).toThrow();
    expect(() => validateFetchUrl('gopher://x/', PROD)).toThrow();
  });

  it('rejects private / loopback / link-local / metadata IPv4 literals', () => {
    for (const h of [
      'https://10.0.0.5/',
      'https://127.0.0.1/',
      'https://192.168.1.1/',
      'https://169.254.169.254/',
      'https://100.64.0.1/',
    ]) {
      expect(() => validateFetchUrl(h, PROD)).toThrow();
    }
  });

  it('rejects IPv6 loopback and IPv4-mapped metadata literals', () => {
    expect(() => validateFetchUrl('https://[::1]/', PROD)).toThrow();
    expect(() => validateFetchUrl('https://[::ffff:169.254.169.254]/', PROD)).toThrow();
  });

  it('rejects internal TLDs', () => {
    expect(() => validateFetchUrl('https://db.internal/', PROD)).toThrow();
    expect(() => validateFetchUrl('https://printer.local/', PROD)).toThrow();
  });

  it('permits http://localhost only when localDev is enabled', () => {
    expect(() => validateFetchUrl('http://localhost:4943/', PROD)).toThrow();
    expect(validateFetchUrl('http://localhost:4943/', { localDev: true }).hostname).toBe(
      'localhost',
    );
  });
});

describe('MCP SSRF: safeFetch redirect re-validation (S2)', () => {
  // Resolve any test host to a public IP so the SEC-0 DNS-rebinding check passes; the redirect /
  // re-validation logic under test is independent of resolution. Rebinding itself is tested below.
  const PUBLIC_LOOKUP = async () => [{ address: '93.184.216.34', family: 4 }];

  it('follows a redirect to a safe https host, re-validating each hop', async () => {
    const fetchImpl = async (url: string) => {
      if (url === 'https://a.example/start')
        return new Response(null, {
          status: 302,
          headers: { location: 'https://b.example/final' },
        });
      if (url === 'https://b.example/final') return new Response('ok', { status: 200 });
      throw new Error(`unexpected fetch: ${url}`);
    };
    const resp = await safeFetch('https://a.example/start', undefined, {
      localDev: false,
      fetchImpl,
      lookupImpl: PUBLIC_LOOKUP,
    });
    expect(resp.status).toBe(200);
    expect(await resp.text()).toBe('ok');
  });

  it('BLOCKS a redirect to the cloud-metadata IP and never fetches it', async () => {
    const seen: string[] = [];
    const fetchImpl = async (url: string) => {
      seen.push(url);
      if (url === 'https://evil.example/start')
        return new Response(null, {
          status: 302,
          headers: { location: 'https://169.254.169.254/latest/' },
        });
      return new Response('SHOULD NOT BE REACHED', { status: 200 });
    };
    await expect(
      safeFetch('https://evil.example/start', undefined, {
        localDev: false,
        fetchImpl,
        lookupImpl: PUBLIC_LOOKUP,
      }),
    ).rejects.toThrow(/metadata|private|loopback/i);
    // The validated origin was fetched, but the redirect target never was.
    expect(seen).toEqual(['https://evil.example/start']);
  });

  it('BLOCKS a redirect that downgrades to http:// (e.g. an internal host)', async () => {
    const fetchImpl = async (url: string) => {
      if (url === 'https://evil.example/start')
        return new Response(null, { status: 301, headers: { location: 'http://10.0.0.9/admin' } });
      return new Response('NOPE', { status: 200 });
    };
    await expect(
      safeFetch('https://evil.example/start', undefined, {
        localDev: false,
        fetchImpl,
        lookupImpl: PUBLIC_LOOKUP,
      }),
    ).rejects.toThrow(/http:\/\//);
  });

  it('refuses to follow more than maxRedirects hops', async () => {
    const fetchImpl = async () =>
      new Response(null, { status: 302, headers: { location: 'https://loop.example/x' } });
    await expect(
      safeFetch('https://loop.example/x', undefined, {
        localDev: false,
        fetchImpl,
        maxRedirects: 3,
        lookupImpl: PUBLIC_LOOKUP,
      }),
    ).rejects.toThrow(/more than 3 redirects/);
  });

  it('returns a non-redirect response directly', async () => {
    const fetchImpl = async () => new Response('hello', { status: 200 });
    const resp = await safeFetch('https://example.com/', undefined, {
      localDev: false,
      fetchImpl,
      lookupImpl: PUBLIC_LOOKUP,
    });
    expect(await resp.text()).toBe('hello');
  });

  it('BLOCKS DNS-rebinding: a public host that resolves to a private IP (SEC-0)', async () => {
    let fetched = false;
    const fetchImpl = async () => {
      fetched = true;
      return new Response('SHOULD NOT BE REACHED', { status: 200 });
    };
    // The literal host is public, but it resolves to an internal address (cloud metadata).
    const rebind = async () => [{ address: '169.254.169.254', family: 4 }];
    await expect(
      safeFetch('https://rebind.example/', undefined, {
        localDev: false,
        fetchImpl,
        lookupImpl: rebind,
      }),
    ).rejects.toThrow(/rebinding|private|internal/i);
    expect(fetched).toBe(false);
  });
});

// 2.22.0 (I11): SSRF guard gaps.
describe('MCP SSRF: 2.22.0 gaps (I11)', () => {
  const PUBLIC_LOOKUP = async () => [{ address: '93.184.216.34', family: 4 }];

  // Fails on: isPrivateIpv6 applied to hostnames again (the startsWith('fd'/'fc'/'fe8') test).
  it('does not read a hostname as an IPv6 address (fda.gov, fc2.com, fe80.example)', () => {
    for (const h of ['https://fda.gov/', 'https://fc2.com/', 'https://fe80.example/']) {
      expect(validateFetchUrl(h, PROD).protocol).toBe('https:');
    }
    expect(isPrivateIpv6('fdic.gov')).toBe(false);
    expect(isPrivateIpv6('[fd00::1]')).toBe(true); // a real ULA literal still refused
    expect(isPrivateIpv6('fe80::1%eth0')).toBe(true);
  });

  // Fails on: NAT64 / 6to4 forms not unwrapped to their embedded IPv4.
  it('refuses NAT64 64:ff9b::/96 and 6to4 2002::/16 forms of private IPv4', () => {
    expect(() => validateFetchUrl('https://[64:ff9b::169.254.169.254]/', PROD)).toThrow(/IPv6/);
    expect(() => validateFetchUrl('https://[64:ff9b::a00:1]/', PROD)).toThrow(/IPv6/); // 10.0.0.1
    expect(() => validateFetchUrl('https://[2002:a9fe:a9fe::1]/', PROD)).toThrow(/IPv6/);
    expect(() => validateFetchUrl('https://[2002:7f00:1::]/', PROD)).toThrow(/IPv6/); // 127.0.0.1
    // public IPv4 behind NAT64 / 6to4 stays reachable (DNS64 networks synthesize these)
    expect(isPrivateIpv6('64:ff9b::808:808')).toBe(false);
    expect(isPrivateIpv6('2002:808:808::1')).toBe(false);
  });

  // Fails on: 198.18.0.0/15 or 240.0.0.0/4 missing from isPrivateIpv4.
  it('refuses 198.18.0.0/15 and 240.0.0.0/4', async () => {
    for (const h of ['198.18.0.1', '198.19.255.254', '240.0.0.1', '255.255.255.255']) {
      expect(() => validateFetchUrl(`https://${h}/`, PROD)).toThrow(/IPv4/);
    }
    await expect(
      assertResolvedHostIsPublic('bench.example', {
        localDev: false,
        lookupImpl: async () => [{ address: '198.18.4.4', family: 4 }],
      }),
    ).rejects.toThrow(/rebinding/);
    expect(() => validateFetchUrl('https://198.20.0.1/', PROD)).not.toThrow();
  });

  // Fails on: probeChallenge following redirects without the DNS check (the old probe path only
  // checked a hop's literal host).
  it('the x402 probe DNS-checks every redirect hop', async () => {
    const seen: string[] = [];
    const fetchImpl = async (url: string) => {
      seen.push(url);
      if (url === 'https://pay.example/x')
        return new Response(null, {
          status: 302,
          headers: { location: 'https://internal.example/' },
        });
      return new Response('SHOULD NOT BE REACHED', { status: 402 });
    };
    const lookupImpl = async (host: string) =>
      host === 'internal.example'
        ? [{ address: '10.1.2.3', family: 4 }]
        : [{ address: '93.184.216.34', family: 4 }];
    await expect(
      probeChallenge('https://pay.example/x', undefined, {
        localDev: false,
        fetchImpl,
        lookupImpl,
      }),
    ).rejects.toThrow(/rebinding/);
    expect(seen).toEqual(['https://pay.example/x']);
  });

  it('the x402 probe returns the payment-required header JSON, or the body', async () => {
    const json = '{"accepts":[]}';
    const viaHeader = await probeChallenge('https://pay.example/', undefined, {
      localDev: false,
      lookupImpl: PUBLIC_LOOKUP,
      fetchImpl: async () =>
        new Response('ignored', { status: 402, headers: { 'payment-required': btoa(json) } }),
    });
    expect(viaHeader.paymentJson).toBe(json);
    const free = await probeChallenge('https://pay.example/', undefined, {
      localDev: false,
      lookupImpl: PUBLIC_LOOKUP,
      fetchImpl: async () => new Response('free body', { status: 200 }),
    });
    expect(free).toMatchObject({ status: 200, ok: true, body: 'free body' });
  });

  // Fails on: readTextCapped reading without the limit (or the probe reading with resp.text()).
  it('caps fetched bodies: a declared or streamed body over the limit is refused', async () => {
    expect(await readTextCapped(new Response('hello'), 5)).toBe('hello');
    await expect(readTextCapped(new Response('hello!'), 5)).rejects.toThrow(/limit/);
    const stream = new ReadableStream<Uint8Array>({
      start(c) {
        c.enqueue(new Uint8Array(4));
        c.enqueue(new Uint8Array(4));
        c.close();
      },
    });
    await expect(readTextCapped(new Response(stream), 6)).rejects.toThrow(/limit/);
    const huge = new Response('x', { status: 402, headers: { 'content-length': '999999999' } });
    await expect(
      probeChallenge('https://pay.example/', undefined, {
        localDev: false,
        lookupImpl: PUBLIC_LOOKUP,
        fetchImpl: async () => huge,
      }),
    ).rejects.toThrow(/limit/);
  });
});

// 2.22.0 (I8): the replica root key is fetched only for local development on an exact local host.
describe('shouldFetchRootKey (I8)', () => {
  // Fails on: the old host.includes('localhost') test, or ignoring localDev.
  it('needs localDev AND an exact localhost / 127.0.0.1 / [::1] host', () => {
    expect(shouldFetchRootKey('http://localhost:4944', true)).toBe(true);
    expect(shouldFetchRootKey('http://127.0.0.1:8080', true)).toBe(true);
    expect(shouldFetchRootKey('http://[::1]:4943', true)).toBe(true);
    expect(shouldFetchRootKey('http://localhost:4944', false)).toBe(false);
    expect(shouldFetchRootKey('https://localhost.evil.example', true)).toBe(false);
    expect(shouldFetchRootKey('https://evil.example/localhost', true)).toBe(false);
    expect(shouldFetchRootKey('http://localhost@evil.example', true)).toBe(false);
    expect(shouldFetchRootKey('https://icp-api.io', true)).toBe(false);
    expect(shouldFetchRootKey('not a url', true)).toBe(false);
  });
});

// 2.22.0: the PAID x402 request. Any failure once it was attempted is possibly paid — the MCP must
// not report it as a plain (retryable) error.
describe('sendPaidRequest (possibly paid after send)', () => {
  const PUBLIC_LOOKUP = async () => [{ address: '93.184.216.34', family: 4 }];
  const send = (fetchImpl: (url: string, init?: RequestInit) => Promise<Response>) =>
    sendPaidRequest(
      'https://pay.example/',
      { 'X-Payment': 'h' },
      { localDev: false, lookupImpl: PUBLIC_LOOKUP, fetchImpl },
    );

  // Fails on: sendPaidRequest letting the error escape (the caller then reported kind "unknown",
  // with no possibly-paid hint, for a timeout or an oversized paid body).
  it('a network error, an abort or an oversized body comes back possiblyPaid', async () => {
    const outcomes = [
      await send(async () => {
        throw new Error('fetch failed');
      }),
      await send(async () => {
        throw new DOMException('This operation was aborted', 'AbortError');
      }),
      await send(
        async () => new Response('x', { status: 200, headers: { 'content-length': '999999999' } }),
      ),
    ];
    for (const o of outcomes) expect(o.kind).toBe('possiblyPaid');
  });

  it('passes the payment header and returns the response', async () => {
    let header: string | null = null;
    const o = await send(async (_url, init) => {
      header = new Headers(init?.headers).get('X-Payment');
      return new Response('content', { status: 200 });
    });
    expect(header).toBe('h');
    expect(o).toEqual({ kind: 'response', status: 200, ok: true, body: 'content' });
  });
});
