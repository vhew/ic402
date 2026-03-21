import { describe, it, expect } from 'vitest';

describe('agentflow integration', () => {
  it.todo('charge: full payment flow (require → approve → settle → receipt)');
  it.todo('charge: rejects amount exceeding maxPerTransaction');
  it.todo('charge: rejects blocked caller');
  it.todo('session: open → voucher x N → close → receipt + refund');
  it.todo('session: rejects voucher exceeding deposit');
  it.todo('session: rejects out-of-sequence voucher');
  it.todo('session: idle timeout auto-closes');
  it.todo('session: maxConcurrentSessions enforced');
  it.todo('daily aggregate tracks charges + session consumption');
});
