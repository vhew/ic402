"""agentflow Python SDK — typed exception hierarchy."""

from __future__ import annotations
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .types import PaymentRequirement


class AgentflowError(Exception):
    """Base exception for all agentflow errors."""


class PaymentRequiredError(AgentflowError):
    """Raised when a canister returns #paymentRequired.
    Inspect .requirement to get price, token, and nonce."""

    def __init__(self, requirement: "PaymentRequirement") -> None:
        self.requirement = requirement
        super().__init__(
            f"Payment required: {requirement.amount} {requirement.token} "
            f"on {requirement.network}"
        )


class BudgetExceededError(AgentflowError):
    """Raised before making a call when client-side budget would be breached."""

    def __init__(self, requested: int, limit: int, kind: str = "request") -> None:
        self.requested = requested
        self.limit = limit
        super().__init__(f"Budget exceeded: {requested} > {limit} ({kind} limit)")


class PolicyDeniedError(AgentflowError):
    """Raised when the canister policy engine rejects the call."""

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"Policy denied: {reason}")


class SessionError(AgentflowError):
    """Base for session-related errors."""


class InsufficientDepositError(SessionError):
    def __init__(self, consumed: int, deposited: int) -> None:
        super().__init__(f"Session budget exhausted: consumed={consumed}, deposited={deposited}")


class InvalidVoucherError(SessionError):
    def __init__(self, reason: str = "") -> None:
        super().__init__(f"Invalid voucher{': ' + reason if reason else ''}")


class SessionClosedError(SessionError):
    def __init__(self, session_id: str) -> None:
        super().__init__(f"Session {session_id!r} is already closed")


class CanisterError(AgentflowError):
    """Wraps raw transport or decoding errors from the ICP canister."""

    def __init__(self, message: str, cause: Exception | None = None) -> None:
        super().__init__(message)
        self.__cause__ = cause
