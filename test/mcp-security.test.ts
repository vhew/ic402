import { describe, it, expect } from 'vitest';
import { validateFetchUrl, safeFetch } from '../integrations/mcp/src/security';

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
      safeFetch('https://evil.example/start', undefined, { localDev: false, fetchImpl }),
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
      safeFetch('https://evil.example/start', undefined, { localDev: false, fetchImpl }),
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
      }),
    ).rejects.toThrow(/more than 3 redirects/);
  });

  it('returns a non-redirect response directly', async () => {
    const fetchImpl = async () => new Response('hello', { status: 200 });
    const resp = await safeFetch('https://example.com/', undefined, { localDev: false, fetchImpl });
    expect(await resp.text()).toBe('hello');
  });
});
