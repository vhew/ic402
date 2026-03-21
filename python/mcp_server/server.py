"""
agentflow MCP Server

Exposes agentflow-enabled ICP canisters as MCP tools.
Any MCP-compatible client (Claude Desktop, Cursor, etc.) can call
paid ICP services — payment is handled transparently at this layer.

Usage:
    agentflow-mcp                          # reads from env vars
    mcp dev python/mcp_server/server.py    # dev mode with inspector

Environment variables:
    AGENTFLOW_PRIVATE_KEY_HEX   32-byte Ed25519 seed as hex (required)
    AGENTFLOW_CANISTER_ID       default canister principal (required)
    AGENTFLOW_NETWORK           CAIP-2 network, default "icp:1"
    AGENTFLOW_SIMULATION        "true" to use mock responses (default false)
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any, Optional

from dotenv import load_dotenv
from mcp.server.fastmcp import FastMCP

# Allow running from repo root: python python/mcp_server/server.py
sys.path.insert(0, str(Path(__file__).parent.parent))

load_dotenv()

from agentflow import (
    AgentflowClient,
    BudgetConfig,
    PaymentRequiredError,
    SessionHandle,
    client_from_env,
    client_from_hex,
)
from agentflow.exceptions import AgentflowError, CanisterError

# ── Server state ──────────────────────────────────────────────────────────────

mcp = FastMCP(
    "agentflow",
    instructions=(
        "agentflow gives you access to ICP canisters that charge micropayments. "
        "Start with setup_identity, then call_canister or open_session. "
        "Sessions are cheaper for repeated calls — use them when making >5 queries."
    ),
)

_client: Optional[AgentflowClient] = None
_sessions: dict[str, SessionHandle] = {}


def _get_client() -> AgentflowClient:
    if _client is None:
        raise RuntimeError(
            "Client not initialised. Call setup_identity first, "
            "or set AGENTFLOW_PRIVATE_KEY_HEX and AGENTFLOW_CANISTER_ID env vars."
        )
    return _client


# ── Tools ─────────────────────────────────────────────────────────────────────

@mcp.tool()
def setup_identity(
    private_key_hex: str,
    canister_id: str,
    network: str = "icp:1",
    simulation: bool = False,
) -> dict:
    """
    Initialise the agentflow client with an Ed25519 identity.

    Args:
        private_key_hex: 32-byte Ed25519 private key seed as a hex string.
        canister_id:     ICP canister principal to interact with.
        network:         CAIP-2 network identifier (default: icp:1 = mainnet).
        simulation:      Use mock responses instead of a live canister (great for testing).

    Returns principal string so you can confirm the identity loaded correctly.
    """
    global _client
    _client = client_from_hex(
        private_key_hex, canister_id, network=network, simulation=simulation
    )
    return {
        "status": "ok",
        "principal": _client.principal(),
        "canister_id": canister_id,
        "network": network,
        "simulation": simulation,
    }


@mcp.tool()
async def call_canister(
    method: str,
    args: list[Any],
    canister_id: Optional[str] = None,
) -> dict:
    """
    Call a canister method. Automatically handles 402 PaymentRequired responses.

    If the canister requires payment, returns a structured payment_required response
    with the amount and token so you can decide whether to proceed.

    Args:
        method:      Canister method name (e.g. "search").
        args:        Method arguments as a JSON array.
        canister_id: Override the default canister (optional).

    Returns the canister response or a payment_required dict.
    """
    client = _get_client()
    try:
        result = await client.call(method, *args, canister_id=canister_id)
        return {"status": "ok", "result": result}
    except PaymentRequiredError as e:
        req = e.requirement
        return {
            "status": "payment_required",
            "message": (
                f"This endpoint costs {req.amount} {req.token} on {req.network}. "
                "Use open_session for cheaper repeated calls, or approve ICRC-2 manually."
            ),
            "requirement": {
                "scheme": req.scheme,
                "network": req.network,
                "token": req.token,
                "amount": req.amount,
                "recipient": req.recipient,
            },
        }
    except AgentflowError as e:
        return {"status": "error", "error": str(e)}


@mcp.tool()
async def request_session_intent(canister_id: Optional[str] = None) -> dict:
    """
    Ask the canister for a session offer — see pricing before committing funds.

    Returns suggested deposit, minimum deposit, cost per call, and description.
    Use this to understand the cost before calling open_session.

    Args:
        canister_id: Override the default canister (optional).
    """
    client = _get_client()
    try:
        intent = await client.request_session(canister_id)
        return {
            "status": "ok",
            "network": intent.network,
            "token": intent.token,
            "suggested_deposit": intent.suggested_deposit,
            "min_deposit": intent.min_deposit,
            "cost_per_call": intent.cost_per_call,
            "description": intent.description,
            "note": (
                f"A session deposit of {intent.suggested_deposit} covers ~"
                f"{intent.suggested_deposit // (intent.cost_per_call or 1000)} calls. "
                "Unused funds are refunded on close."
            ),
        }
    except AgentflowError as e:
        return {"status": "error", "error": str(e)}


@mcp.tool()
async def open_session(
    max_deposit: Optional[int] = None,
    canister_id: Optional[str] = None,
) -> dict:
    """
    Open a streaming payment session with the canister.

    Deposits funds into escrow once, then calls are paid via signed vouchers —
    no on-chain transaction per call. Unused funds are refunded when you close.

    Args:
        max_deposit:  Maximum amount to lock in escrow (optional, uses canister suggestion).
        canister_id:  Override the default canister (optional).

    Returns session_id to use with session_call and close_session.
    """
    client = _get_client()
    try:
        handle = await client.open_session(max_deposit=max_deposit, canister_id=canister_id)
        _sessions[handle.id] = handle
        return {
            "status": "ok",
            "session_id": handle.id,
            "deposited": handle.deposited,
            "remaining": handle.remaining,
            "note": (
                "Session open. Use session_call to make paid requests. "
                "Call close_session when done to receive your refund."
            ),
        }
    except AgentflowError as e:
        return {"status": "error", "error": str(e)}


@mcp.tool()
async def session_call(
    session_id: str,
    method: str,
    args: list[Any],
) -> dict:
    """
    Call a canister method using an open session (pays via signed voucher).

    Much cheaper than per-call charges for repeated queries.
    Automatically signs and includes the voucher — no manual signing needed.

    Args:
        session_id: Session ID returned by open_session.
        method:     Canister method name (e.g. "sessionQuery").
        args:       Method arguments as a JSON array.
    """
    handle = _sessions.get(session_id)
    if not handle:
        return {"status": "error", "error": f"Session {session_id!r} not found. Call open_session first."}

    try:
        result = await handle.call(method, *args)
        return {
            "status": "ok",
            "result": result,
            "session_id": session_id,
            "voucher_sequence": handle._sequence,
            "consumed": handle.consumed,
            "remaining": handle.remaining,
        }
    except AgentflowError as e:
        return {"status": "error", "error": str(e)}


@mcp.tool()
async def close_session(session_id: str) -> dict:
    """
    Close a session, settle on-chain, and refund unused funds.

    Args:
        session_id: Session ID returned by open_session.

    Returns a payment receipt with consumed amount and refunded amount.
    """
    handle = _sessions.get(session_id)
    if not handle:
        return {"status": "error", "error": f"Session {session_id!r} not found."}

    try:
        receipt = await handle.close()
        _sessions.pop(session_id, None)
        return {
            "status": "ok",
            "receipt_id": receipt.id,
            "consumed": receipt.amount,
            "refunded": receipt.refunded,
            "token": receipt.token,
            "network": receipt.network,
        }
    except AgentflowError as e:
        return {"status": "error", "error": str(e)}


@mcp.tool()
def get_session_status(session_id: Optional[str] = None) -> dict:
    """
    Check the status of one or all open sessions.

    Args:
        session_id: Specific session to check. If omitted, lists all open sessions.
    """
    if session_id:
        handle = _sessions.get(session_id)
        if not handle:
            return {"status": "error", "error": f"Session {session_id!r} not found."}
        return {
            "session_id": handle.id,
            "deposited": handle.deposited,
            "consumed": handle.consumed,
            "remaining": handle.remaining,
            "voucher_count": handle._sequence,
        }

    return {
        "open_sessions": [
            {
                "session_id": h.id,
                "deposited": h.deposited,
                "consumed": h.consumed,
                "remaining": h.remaining,
            }
            for h in _sessions.values()
        ],
        "count": len(_sessions),
    }


@mcp.tool()
def approve_icrc2(spender_principal: str, amount: int, token_ledger: str) -> dict:
    """
    [STUB] Approve an ICRC-2 token allowance for the canister to pull funds.

    This step is required before open_session and call_canister with auto-payment.
    Currently not implemented in the SDK — use dfx to approve manually.

    Args:
        spender_principal: The canister principal that will pull the funds.
        amount:            Amount to approve in token base units.
        token_ledger:      ICRC-2 ledger canister principal.
    """
    client = _get_client() if _client else None
    return {
        "status": "stub",
        "message": (
            "ICRC-2 approval is not yet implemented in the Python SDK. "
            "Approve manually with dfx:"
        ),
        "dfx_command": (
            f"dfx canister call {token_ledger} icrc2_approve "
            f"'(record {{ spender = record {{ owner = principal \"{spender_principal}\"; subaccount = null }}; "
            f"amount = {amount} }})'"
        ),
        "spender": spender_principal,
        "amount": amount,
        "token_ledger": token_ledger,
    }


# ── Auto-init from env ────────────────────────────────────────────────────────

def _try_init_from_env() -> None:
    """If env vars are set, initialise the client at startup."""
    global _client
    key_hex = os.getenv("AGENTFLOW_PRIVATE_KEY_HEX")
    canister_id = os.getenv("AGENTFLOW_CANISTER_ID")
    if key_hex and canister_id:
        simulation = os.getenv("AGENTFLOW_SIMULATION", "false").lower() == "true"
        _client = client_from_hex(
            key_hex,
            canister_id,
            network=os.getenv("AGENTFLOW_NETWORK", "icp:1"),
            simulation=simulation,
        )


_try_init_from_env()


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
