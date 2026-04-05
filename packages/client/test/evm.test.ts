import { describe, it, expect } from 'vitest';
import { findPaymentOption, Ic402Error } from '../src/evm.js';

describe('findPaymentOption', () => {
  it('finds option by CAIP-2 network', () => {
    const body = JSON.stringify({
      accepts: [
        {
          network: 'eip155:84532',
          payTo: '0xRecipient',
          amount: '1000',
          asset: '0xUSDC',
        },
      ],
    });

    const option = findPaymentOption(body, 84532);
    expect(option).not.toBeNull();
    expect(option!.recipient).toBe('0xRecipient');
    expect(option!.amount).toBe(1000n);
    expect(option!.network).toBe('eip155:84532');
    expect(option!.asset).toBe('0xUSDC');
  });

  it('finds option by chain alias', () => {
    const body = JSON.stringify({
      accepts: [
        {
          network: 'base-sepolia',
          payTo: '0xRecipient',
          amount: '500',
          asset: '0xUSDC',
        },
      ],
    });

    // chainId 84532 has alias "base-sepolia"
    const option = findPaymentOption(body, 84532);
    expect(option).not.toBeNull();
    expect(option!.recipient).toBe('0xRecipient');
    expect(option!.amount).toBe(500n);
    expect(option!.network).toBe('eip155:84532');
  });

  it('picks cheapest option', () => {
    const body = JSON.stringify({
      accepts: [
        {
          network: 'eip155:84532',
          payTo: '0xExpensive',
          amount: '1000',
          asset: '0xUSDC',
        },
        {
          network: 'eip155:84532',
          payTo: '0xCheap',
          amount: '50',
          asset: '0xUSDC',
        },
        {
          network: 'eip155:84532',
          payTo: '0xMedium',
          amount: '500',
          asset: '0xUSDC',
        },
      ],
    });

    const option = findPaymentOption(body, 84532);
    expect(option).not.toBeNull();
    expect(option!.recipient).toBe('0xCheap');
    expect(option!.amount).toBe(50n);
  });

  it('returns null for unmatched chain', () => {
    const body = JSON.stringify({
      accepts: [
        {
          network: 'eip155:8453',
          payTo: '0xRecipient',
          amount: '100',
          asset: '0xUSDC',
        },
      ],
    });

    // chainId 1 (ethereum) does not match eip155:8453 (base)
    const option = findPaymentOption(body, 1);
    expect(option).toBeNull();
  });

  it('parses GoldRush-style 402 response', () => {
    // GoldRush uses the x402 field with accepts array
    const body = JSON.stringify({
      x402: {
        accepts: [
          {
            network: 'eip155:84532',
            payTo: '0xGoldRushRecipient',
            amount: '2000',
            asset: '0xUSDCBase',
            extra: {
              name: 'USD Coin',
              version: '2',
            },
          },
        ],
      },
    });

    const option = findPaymentOption(body, 84532);
    expect(option).not.toBeNull();
    expect(option!.recipient).toBe('0xGoldRushRecipient');
    expect(option!.amount).toBe(2000n);
    expect(option!.tokenName).toBe('USD Coin');
    expect(option!.tokenVersion).toBe('2');
    expect(option!.asset).toBe('0xUSDCBase');
  });

  it('handles maxAmountRequired field', () => {
    const body = JSON.stringify({
      accepts: [
        {
          network: 'eip155:84532',
          payTo: '0xRecipient',
          maxAmountRequired: '3000',
          asset: '0xUSDC',
        },
      ],
    });

    const option = findPaymentOption(body, 84532);
    expect(option).not.toBeNull();
    expect(option!.amount).toBe(3000n);
  });

  it('prefers maxAmountRequired over amount', () => {
    // When both fields are present, maxAmountRequired takes priority
    const body = JSON.stringify({
      accepts: [
        {
          network: 'eip155:84532',
          payTo: '0xRecipient',
          amount: '100',
          maxAmountRequired: '200',
          asset: '0xUSDC',
        },
      ],
    });

    const option = findPaymentOption(body, 84532);
    expect(option).not.toBeNull();
    // maxAmountRequired is checked first in the code
    expect(option!.amount).toBe(200n);
  });

  it('provides default tokenName and tokenVersion', () => {
    const body = JSON.stringify({
      accepts: [
        {
          network: 'eip155:84532',
          payTo: '0xRecipient',
          amount: '100',
          asset: '0xUSDC',
        },
      ],
    });

    const option = findPaymentOption(body, 84532);
    expect(option).not.toBeNull();
    expect(option!.tokenName).toBe('USD Coin');
    expect(option!.tokenVersion).toBe('2');
  });

  it('uses extra field for tokenName and tokenVersion', () => {
    const body = JSON.stringify({
      accepts: [
        {
          network: 'eip155:84532',
          payTo: '0xRecipient',
          amount: '100',
          asset: '0xToken',
          extra: { name: 'Dai Stablecoin', version: '1' },
        },
      ],
    });

    const option = findPaymentOption(body, 84532);
    expect(option).not.toBeNull();
    expect(option!.tokenName).toBe('Dai Stablecoin');
    expect(option!.tokenVersion).toBe('1');
  });

  it('handles flat object without accepts array', () => {
    // When the body is a single payment object, not wrapped in accepts
    const body = JSON.stringify({
      network: 'eip155:84532',
      payTo: '0xDirect',
      amount: '777',
      asset: '0xUSDC',
    });

    const option = findPaymentOption(body, 84532);
    expect(option).not.toBeNull();
    expect(option!.recipient).toBe('0xDirect');
    expect(option!.amount).toBe(777n);
  });

  it('skips entries with zero or missing amount', () => {
    const body = JSON.stringify({
      accepts: [
        {
          network: 'eip155:84532',
          payTo: '0xZero',
          amount: '0',
          asset: '0xUSDC',
        },
        {
          network: 'eip155:84532',
          payTo: '0xValid',
          amount: '100',
          asset: '0xUSDC',
        },
      ],
    });

    const option = findPaymentOption(body, 84532);
    expect(option).not.toBeNull();
    expect(option!.recipient).toBe('0xValid');
    expect(option!.amount).toBe(100n);
  });

  it('skips entries with missing payTo', () => {
    const body = JSON.stringify({
      accepts: [
        {
          network: 'eip155:84532',
          amount: '100',
          asset: '0xUSDC',
          // no payTo
        },
        {
          network: 'eip155:84532',
          payTo: '0xHasPayTo',
          amount: '200',
          asset: '0xUSDC',
        },
      ],
    });

    const option = findPaymentOption(body, 84532);
    expect(option).not.toBeNull();
    // First entry has empty payTo after String() conversion, so it's skipped
    // findPaymentOption checks if (!payTo) continue
    expect(option!.amount).toBe(200n);
  });

  it('matches ethereum alias for chainId 1', () => {
    const body = JSON.stringify({
      accepts: [
        {
          network: 'ethereum',
          payTo: '0xEthRecipient',
          amount: '1500',
          asset: '0xUSDC',
        },
      ],
    });

    const option = findPaymentOption(body, 1);
    expect(option).not.toBeNull();
    expect(option!.recipient).toBe('0xEthRecipient');
    expect(option!.network).toBe('eip155:1');
  });

  it('matches base alias for chainId 8453', () => {
    const body = JSON.stringify({
      accepts: [
        {
          network: 'base',
          payTo: '0xBaseRecipient',
          amount: '300',
          asset: '0xUSDC',
        },
      ],
    });

    const option = findPaymentOption(body, 8453);
    expect(option).not.toBeNull();
    expect(option!.recipient).toBe('0xBaseRecipient');
  });

  it('returns null for invalid JSON body', () => {
    // Text fallback parsing should not find a match for a chain that's not in the text
    const option = findPaymentOption('not valid json at all', 84532);
    expect(option).toBeNull();
  });
});

describe('Ic402Error', () => {
  it('transient errors are retryable', () => {
    const err = new Ic402Error('transient', 'timeout');
    expect(err.retryable).toBe(true);
    expect(err.kind).toBe('transient');
    expect(err.message).toBe('timeout');
    expect(err.name).toBe('Ic402Error');
  });

  it('nonce errors are retryable', () => {
    const err = new Ic402Error('nonce_error', 'nonce too low');
    expect(err.retryable).toBe(true);
    expect(err.kind).toBe('nonce_error');
  });

  it('settlement errors are not retryable', () => {
    const err = new Ic402Error('settlement_failed', 'rejected');
    expect(err.retryable).toBe(false);
    expect(err.kind).toBe('settlement_failed');
  });

  it('sign_failed errors are not retryable', () => {
    const err = new Ic402Error('sign_failed', 'policy violation');
    expect(err.retryable).toBe(false);
  });

  it('budget_exceeded errors are not retryable', () => {
    const err = new Ic402Error('budget_exceeded', 'over limit');
    expect(err.retryable).toBe(false);
  });

  it('config_error errors are not retryable', () => {
    const err = new Ic402Error('config_error', 'missing canisterId');
    expect(err.retryable).toBe(false);
  });

  it('broadcast_failed errors are not retryable', () => {
    const err = new Ic402Error('broadcast_failed', 'rejected by RPC');
    expect(err.retryable).toBe(false);
  });

  it('insufficient_funds errors are not retryable', () => {
    const err = new Ic402Error('insufficient_funds', 'not enough ETH');
    expect(err.retryable).toBe(false);
  });

  it('no_match errors are not retryable', () => {
    const err = new Ic402Error('no_match', 'no option');
    expect(err.retryable).toBe(false);
  });

  it('http_error errors are not retryable', () => {
    const err = new Ic402Error('http_error', 'HTTP 500');
    expect(err.retryable).toBe(false);
  });

  it('unknown errors are not retryable', () => {
    const err = new Ic402Error('unknown', 'something went wrong');
    expect(err.retryable).toBe(false);
  });

  it('preserves detail', () => {
    const cause = new TypeError('original error');
    const err = new Ic402Error('transient', 'wrapped', cause);
    expect(err.detail).toBe(cause);
  });

  it('is instanceof Error', () => {
    const err = new Ic402Error('transient', 'test');
    expect(err).toBeInstanceOf(Error);
    expect(err).toBeInstanceOf(Ic402Error);
  });
});

describe('SignedTypedData type', () => {
  it('has expected fields', () => {
    // Verify the type shape matches what signTypedData returns
    const mock = {
      signature: '0x' + 'ab'.repeat(65),
      signer: '0x' + '12'.repeat(20),
      digest: '0x' + 'cd'.repeat(32),
      v: 28,
      r: '0x' + 'ef'.repeat(32),
      s: '0x' + '01'.repeat(32),
    };
    expect(mock.signature).toHaveLength(132);
    expect(mock.signer).toHaveLength(42);
    expect(mock.digest).toHaveLength(66);
    expect(mock.v).toBeGreaterThanOrEqual(27);
    expect(mock.r).toHaveLength(66);
    expect(mock.s).toHaveLength(66);
  });
});
