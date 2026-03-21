/// Mirrors the Motoko types from src/agentflow/Types.mo.

export interface PaymentRequirement {
  scheme: string;
  network: string;
  token: string;
  amount: bigint;
  recipient: string;
  nonce: Uint8Array;
  expiry: bigint;
}

export interface PaymentReceipt {
  id: string;
  amount: bigint;
  token: string;
  sender: string;
  recipient: string;
  network: string;
  timestamp: bigint;
  txHash?: string;
  sessionId?: string;
  refunded?: bigint;
}

export interface SessionIntent {
  network: string;
  token: string;
  recipient: string;
  suggestedDeposit: bigint;
  minDeposit?: bigint;
  expiry: bigint;
  costPerCall?: bigint;
  description?: string;
}

export interface SessionState {
  id: string;
  deposited: bigint;
  consumed: bigint;
  remaining: bigint;
  voucherCount: bigint;
  status: 'open' | 'closing' | 'closed' | 'expired';
  openedAt: bigint;
  lastActivityAt: bigint;
}

export interface Voucher {
  sessionId: string;
  cumulativeAmount: bigint;
  sequence: bigint;
  signature: Uint8Array;
}
