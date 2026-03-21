"""
agentflow Python SDK — type definitions.
Mirrors src/agentflow/Types.mo and packages/client/src/types.ts exactly.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal, Optional


# ── Token & Pricing ──────────────────────────────────────────────────────────

@dataclass(frozen=True)
class TokenConfig:
    ledger: str      # canister principal text
    symbol: str
    decimals: int


@dataclass(frozen=True)
class Price:
    token: str       # ledger principal text
    amount: int      # in token's smallest unit
    network: str     # CAIP-2, e.g. "icp:1"


# ── Charge (x402) ────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class PaymentRequirement:
    scheme: str      # "exact"
    network: str
    token: str
    amount: int
    recipient: str
    nonce: bytes
    expiry: int      # nanoseconds timestamp


@dataclass(frozen=True)
class PaymentSignature:
    scheme: str
    network: str
    signature: bytes
    sender: str
    nonce: bytes


@dataclass(frozen=True)
class PaymentReceipt:
    id: str
    amount: int
    token: str
    sender: str
    recipient: str
    network: str
    timestamp: int
    tx_hash: Optional[str] = None
    session_id: Optional[str] = None
    refunded: Optional[int] = None


# ── Session ───────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class SessionIntent:
    network: str
    token: str
    recipient: str
    suggested_deposit: int
    expiry: int
    min_deposit: Optional[int] = None
    cost_per_call: Optional[int] = None
    description: Optional[str] = None


@dataclass(frozen=True)
class SessionConfig:
    max_deposit: int
    auto_close: bool = True
    idle_timeout: Optional[int] = None   # nanoseconds


SessionStatus = Literal["open", "closing", "closed", "expired"]


@dataclass
class SessionState:
    id: str
    deposited: int
    consumed: int
    remaining: int
    voucher_count: int
    status: SessionStatus
    opened_at: int
    last_activity_at: int


@dataclass(frozen=True)
class Voucher:
    session_id: str
    cumulative_amount: int
    sequence: int
    signature: bytes


# ── Policy ───────────────────────────────────────────────────────────────────

@dataclass
class SpendingPolicy:
    max_per_transaction: Optional[int] = None
    max_per_day: Optional[int] = None
    rate_limit_per_minute: Optional[int] = None
    max_session_deposit: Optional[int] = None
    max_concurrent_sessions: Optional[int] = None
    max_session_duration: Optional[int] = None   # nanoseconds
    session_idle_timeout: Optional[int] = None   # nanoseconds
    allowed_callers: Optional[list[str]] = None
    blocked_callers: Optional[list[str]] = None


# ── Client config ─────────────────────────────────────────────────────────────

@dataclass
class BudgetConfig:
    max_per_request: Optional[int] = None
    max_per_day: Optional[int] = None
    max_total: Optional[int] = None
    max_session_deposit: Optional[int] = None
    alert_threshold: Optional[int] = None


@dataclass
class SessionPreferences:
    prefer_session: bool = False
    max_deposit: Optional[int] = None
    auto_close: bool = True
    idle_timeout: Optional[int] = None
