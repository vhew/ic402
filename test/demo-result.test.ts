import { describe, it, expect } from 'vitest';
import { isMcpErrorEnvelope, assertMcpOk, mcpErrorMessage } from '../example/client/src/util';

describe('demo MCP-result interpretation (C6: no false "settled")', () => {
  it('treats the MCP admin-tool error envelope as an error', () => {
    // This is exactly what submit_job_result / claim_job return on a canister-side
    // rejection — a NON-isError result whose JSON is {status:'error', ...}.
    expect(
      isMcpErrorEnvelope({ status: 'error', error: { message: 'job not in submitted status' } }),
    ).toBe(true);
    expect(isMcpErrorEnvelope({ err: 'Not the buyer' })).toBe(true);
    expect(isMcpErrorEnvelope({ error: 'Service unavailable' })).toBe(true);
  });

  it('treats ok/free/plain results as NOT errors', () => {
    expect(isMcpErrorEnvelope({ status: 'ok', jobId: 'job-1' })).toBe(false);
    expect(isMcpErrorEnvelope({ status: 'free', code: 200 })).toBe(false);
    expect(isMcpErrorEnvelope({ jobId: 'job-1' })).toBe(false);
    expect(isMcpErrorEnvelope('raw text')).toBe(false);
    expect(isMcpErrorEnvelope(null)).toBe(false);
    expect(isMcpErrorEnvelope(undefined)).toBe(false);
  });

  it('assertMcpOk throws on an error envelope (so success() cannot print over a failure)', () => {
    expect(() =>
      assertMcpOk({ status: 'error', error: { message: 'rejected' } }, 'submit_job_result'),
    ).toThrow(/submit_job_result failed: rejected/);
    expect(() => assertMcpOk({ err: 'Not the buyer' }, 'claim_job')).toThrow(/Not the buyer/);
  });

  it('assertMcpOk does NOT throw on a successful result', () => {
    expect(() => assertMcpOk({ status: 'ok', jobId: 'job-1' }, 'submit_job_result')).not.toThrow();
    expect(() => assertMcpOk('some content', 'get_job_result')).not.toThrow();
  });

  it('extracts a readable error message', () => {
    expect(mcpErrorMessage({ error: { message: 'boom' } })).toBe('boom');
    expect(mcpErrorMessage({ err: 'nope' })).toBe('nope');
    expect(mcpErrorMessage({})).toBe('MCP tool returned an error');
  });
});
