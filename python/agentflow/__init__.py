"""
agentflow Python SDK

Drop-in payment client for ICP canisters.
x402 charges, streaming sessions, Ed25519 vouchers.

Quick start:
    from agentflow import AgentflowClient, client_from_env

    client = client_from_env(simulation=True)
    intent = await client.request_session()
    async with await client.open_session(intent) as session:
        result = await session.call("sessionQuery", "explain transformers")
"""

from .client import AgentflowClient, SessionHandle, client_from_env, client_from_hex
from .exceptions import (
    AgentflowError,
    BudgetExceededError,
    CanisterError,
    InsufficientDepositError,
    InvalidVoucherError,
    PaymentRequiredError,
    PolicyDeniedError,
    SessionClosedError,
    SessionError,
)
from .types import (
    BudgetConfig,
    PaymentReceipt,
    PaymentRequirement,
    PaymentSignature,
    SessionConfig,
    SessionIntent,
    SessionPreferences,
    SessionState,
    SpendingPolicy,
    Voucher,
)
from .voucher import encode_voucher_payload, sign_voucher, verify_voucher

__version__ = "0.1.0"
__all__ = [
    # Client
    "AgentflowClient",
    "SessionHandle",
    "client_from_env",
    "client_from_hex",
    # Types
    "BudgetConfig",
    "PaymentReceipt",
    "PaymentRequirement",
    "PaymentSignature",
    "SessionConfig",
    "SessionIntent",
    "SessionPreferences",
    "SessionState",
    "SpendingPolicy",
    "Voucher",
    # Voucher crypto
    "encode_voucher_payload",
    "sign_voucher",
    "verify_voucher",
    # Exceptions
    "AgentflowError",
    "BudgetExceededError",
    "CanisterError",
    "InsufficientDepositError",
    "InvalidVoucherError",
    "PaymentRequiredError",
    "PolicyDeniedError",
    "SessionClosedError",
    "SessionError",
]
