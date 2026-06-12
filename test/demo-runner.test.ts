import { describe, it, expect } from 'vitest';
import { summarizeResults, type StepResult } from '../example/client/src/runner';

describe('demo smoke-test verdict (failures must be obvious)', () => {
  it('PASS (exit 0) when no step failed', () => {
    const results: StepResult[] = [
      { name: 'Configure', status: 'passed' },
      { name: 'Add Content', status: 'passed' },
      { name: 'Delete', status: 'skipped' },
      { name: 'Buy (live API)', status: 'known-issue' },
    ];
    const s = summarizeResults(results);
    expect(s.exitCode).toBe(0);
    expect(s.passed).toBe(2);
    expect(s.skipped).toBe(1);
    expect(s.knownIssues).toBe(1);
    expect(s.failedNames).toEqual([]);
  });

  it('FAIL (exit 1) and names the failed steps when any step failed', () => {
    const results: StepResult[] = [
      { name: 'Configure', status: 'passed' },
      { name: 'Sell Content', status: 'failed', error: 'settle returned {status:error}' },
      { name: 'Buy (live API)', status: 'known-issue' },
    ];
    const s = summarizeResults(results);
    expect(s.exitCode).toBe(1);
    expect(s.failed).toBe(1);
    expect(s.failedNames).toEqual(['Sell Content']);
  });

  it('a known-issue does NOT fail the run (labeled, not masked)', () => {
    const s = summarizeResults([{ name: 'Agent reg (needs faucet ETH)', status: 'known-issue' }]);
    expect(s.exitCode).toBe(0);
    expect(s.knownIssues).toBe(1);
    expect(s.failed).toBe(0);
  });

  it('an empty run is a vacuous pass', () => {
    const s = summarizeResults([]);
    expect(s.total).toBe(0);
    expect(s.exitCode).toBe(0);
  });
});
