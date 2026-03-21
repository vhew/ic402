"""
ic402 Gradio MCP Server

Exposes ic402 payment tools via Gradio's MCP interface.
Connect to Claude Desktop by adding to claude_desktop_config.json:

  {
    "mcpServers": {
      "ic402": {
        "url": "http://localhost:7861/gradio_api/mcp/sse"
      }
    }
  }

Run:
    python python/gradio_mcp.py
    python python/gradio_mcp.py --simulation   # demo mode, no live canister needed

Environment variables (optional — can also use setup_identity tool):
    IC402_PRIVATE_KEY_HEX   32-byte Ed25519 seed as hex
    IC402_CANISTER_ID       target canister principal
    IC402_NETWORK           CAIP-2 network (default: icp:1)
    IC402_SIMULATION        "true" for mock responses
"""

from __future__ import annotations

import json
import os
import sys
from typing import Optional

import gradio as gr
from dotenv import load_dotenv

sys.path.insert(0, os.path.dirname(__file__))
load_dotenv()

from ic402 import (
    AgentflowClient,
    PaymentRequiredError,
    SessionHandle,
    client_from_hex,
)
from ic402.exceptions import AgentflowError

# ── Shared state ──────────────────────────────────────────────────────────────

_client: Optional[AgentflowClient] = None
_sessions: dict[str, SessionHandle] = {}


def _get_client() -> AgentflowClient:
    if _client is None:
        raise RuntimeError(
            "Not initialised. Call setup_identity first, "
            "or set IC402_PRIVATE_KEY_HEX and IC402_CANISTER_ID."
        )
    return _client


def _try_init_from_env() -> None:
    global _client
    key_hex = os.getenv("IC402_PRIVATE_KEY_HEX")
    canister_id = os.getenv("IC402_CANISTER_ID")
    if key_hex and canister_id:
        simulation = os.getenv("IC402_SIMULATION", "false").lower() == "true"
        _client = client_from_hex(
            key_hex, canister_id,
            network=os.getenv("IC402_NETWORK", "icp:1"),
            simulation=simulation,
        )


_try_init_from_env()


# ── Tool functions ────────────────────────────────────────────────────────────

def setup_identity(
    private_key_hex: str,
    canister_id: str,
    network: str = "icp:1",
    simulation: bool = False,
) -> str:
    """
    Initialise the ic402 client with an Ed25519 identity.

    Call this before any other tool. Returns the principal so you can confirm
    the identity loaded correctly.

    Args:
        private_key_hex: 32-byte Ed25519 private key seed as hex (64 chars).
        canister_id:     ICP canister principal to interact with.
        network:         CAIP-2 network identifier (default: icp:1 = mainnet).
        simulation:      Use mock responses without a live canister.
    """
    global _client
    try:
        _client = client_from_hex(
            private_key_hex, canister_id, network=network, simulation=simulation
        )
        return json.dumps({
            "status": "ok",
            "principal": _client.principal(),
            "canister_id": canister_id,
            "network": network,
            "simulation": simulation,
        }, indent=2)
    except Exception as e:
        return json.dumps({"status": "error", "error": str(e)}, indent=2)


async def request_session_intent(canister_id: str = "") -> str:
    """
    Ask the canister for a session offer — see pricing before committing funds.

    Returns suggested deposit, minimum deposit, cost per call, and description.
    Use this to understand the cost before calling open_session.

    Args:
        canister_id: Override the default canister (optional).
    """
    try:
        client = _get_client()
        intent = await client.request_session(canister_id or None)
        return json.dumps({
            "status": "ok",
            "network": intent.network,
            "token": intent.token,
            "suggested_deposit": intent.suggested_deposit,
            "min_deposit": intent.min_deposit,
            "cost_per_call": intent.cost_per_call,
            "description": intent.description,
        }, indent=2)
    except Exception as e:
        return json.dumps({"status": "error", "error": str(e)}, indent=2)


async def open_session(max_deposit: int = 0, canister_id: str = "") -> str:
    """
    Open a streaming micropayment session with escrow deposit.

    Deposits funds once, then calls are paid via signed vouchers — no on-chain
    transaction per call. Unused funds are refunded when you close the session.

    Args:
        max_deposit:  Max amount to lock in escrow (0 = use canister suggestion).
        canister_id:  Override the default canister (optional).

    Returns session_id — use this with session_query and close_session.
    """
    try:
        client = _get_client()
        handle = await client.open_session(
            max_deposit=max_deposit or None,
            canister_id=canister_id or None,
        )
        _sessions[handle.id] = handle
        return json.dumps({
            "status": "ok",
            "session_id": handle.id,
            "deposited": handle.deposited,
            "remaining": handle.remaining,
        }, indent=2)
    except Exception as e:
        return json.dumps({"status": "error", "error": str(e)}, indent=2)


async def session_query(session_id: str, question: str) -> str:
    """
    Send a query through an open session. Automatically signs a payment voucher.

    Each call consumes costPerCall from the session deposit — much cheaper than
    per-call x402 charges for repeated queries.

    Args:
        session_id: Session ID returned by open_session.
        question:   Question or query text to send to the canister.
    """
    handle = _sessions.get(session_id)
    if not handle:
        return json.dumps({"status": "error", "error": f"Session {session_id!r} not found. Call open_session first."})
    try:
        result = await handle.call("sessionQuery", question)
        return json.dumps({
            "status": "ok",
            "result": result,
            "consumed": handle.consumed,
            "remaining": handle.remaining,
            "voucher_sequence": handle._sequence,
        }, indent=2)
    except AgentflowError as e:
        return json.dumps({"status": "error", "error": str(e)}, indent=2)


async def close_session(session_id: str) -> str:
    """
    Close a session, settle on-chain, and refund unused funds.

    Args:
        session_id: Session ID returned by open_session.

    Returns a payment receipt with consumed amount and refunded amount.
    """
    handle = _sessions.get(session_id)
    if not handle:
        return json.dumps({"status": "error", "error": f"Session {session_id!r} not found."})
    try:
        receipt = await handle.close()
        _sessions.pop(session_id, None)
        return json.dumps({
            "status": "ok",
            "receipt_id": receipt.id,
            "consumed": receipt.amount,
            "refunded": receipt.refunded,
            "token": receipt.token,
        }, indent=2)
    except AgentflowError as e:
        return json.dumps({"status": "error", "error": str(e)}, indent=2)


def get_sessions() -> str:
    """
    List all currently open sessions and their balances.

    Returns a list of active sessions with deposited, consumed, and remaining amounts.
    """
    return json.dumps({
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
    }, indent=2)


async def fetch_content(delivery: str, canister_id: str = "") -> str:
    """
    Fetch content from a ContentDelivery response.

    Supports inline (embedded bytes), httpUrl, assetCanister (ICP asset canister),
    and canisterQuery (chunked streaming from canister method) delivery methods.

    Args:
        delivery:    ContentDelivery as a JSON string (returned by content endpoints).
        canister_id: Required for canisterQuery delivery; overrides default canister.
    """
    import httpx

    try:
        parsed = json.loads(delivery)
    except Exception:
        return json.dumps({"status": "error", "error": "Invalid JSON in delivery"})

    grant = parsed.get("grant", {})
    del_ = parsed.get("delivery", {})

    try:
        if "inline" in del_:
            raw = del_["inline"]
            data = bytes.fromhex(raw) if isinstance(raw, str) else bytes(raw)
            text = data.decode("utf-8", errors="replace")

        elif "httpUrl" in del_:
            async with httpx.AsyncClient() as http:
                resp = await http.get(del_["httpUrl"])
                resp.raise_for_status()
                text = resp.text

        elif "assetCanister" in del_:
            ac = del_["assetCanister"]
            url = f"https://{ac['canisterId']}.icp0.io{ac['path']}"
            async with httpx.AsyncClient() as http:
                resp = await http.get(url)
                resp.raise_for_status()
                text = resp.text

        elif "canisterQuery" in del_:
            client = _get_client()
            cid = canister_id or client._canister_id
            method = del_["canisterQuery"]["method"]
            chunk_count = int(del_["canisterQuery"]["chunkCount"])
            chunks = []
            for i in range(chunk_count):
                raw = client._raw_call(method, [grant, i], cid)
                chunk = raw if isinstance(raw, (bytes, bytearray)) else str(raw)
                chunks.append(chunk if isinstance(chunk, str) else chunk.decode("utf-8", errors="replace"))
            text = "".join(chunks)

        else:
            return json.dumps({"status": "error", "error": f"Unknown delivery method: {list(del_.keys())}"})

        return json.dumps({
            "status": "ok",
            "content_id": grant.get("contentRef", {}).get("id"),
            "mime_type": grant.get("contentRef", {}).get("mimeType"),
            "content": text,
        }, indent=2)

    except Exception as e:
        return json.dumps({"status": "error", "error": str(e)}, indent=2)


# ── Gradio app ────────────────────────────────────────────────────────────────

with gr.Blocks(title="ic402 — ICP Payment Tools") as demo:
    gr.Markdown("# ic402 — Autonomous Payments for ICP Canisters")
    gr.Markdown(
        "MCP server for x402 charges and streaming micropayment sessions. "
        "Connect to Claude Desktop at `http://localhost:7861/gradio_api/mcp/sse`"
    )

    with gr.Tab("Setup"):
        gr.Interface(
            fn=setup_identity,
            inputs=[
                gr.Textbox(label="Private Key Hex", type="password", placeholder="64-char hex seed"),
                gr.Textbox(label="Canister ID", placeholder="e.g. rrkah-fqaaa-aaaaa-aaaaq-cai"),
                gr.Textbox(label="Network", value="icp:1"),
                gr.Checkbox(label="Simulation mode", value=False),
            ],
            outputs=gr.Code(label="Result", language="json"),
            flagging_mode="never",
        )

    with gr.Tab("Session"):
        with gr.Row():
            gr.Interface(
                fn=request_session_intent,
                inputs=[gr.Textbox(label="Canister ID (optional)")],
                outputs=gr.Code(label="Session Intent", language="json"),
                flagging_mode="never",
            )
        with gr.Row():
            gr.Interface(
                fn=open_session,
                inputs=[
                    gr.Number(label="Max Deposit (0 = canister suggestion)", value=0, precision=0),
                    gr.Textbox(label="Canister ID (optional)"),
                ],
                outputs=gr.Code(label="Session State", language="json"),
                flagging_mode="never",
            )

    with gr.Tab("Query"):
        gr.Interface(
            fn=session_query,
            inputs=[
                gr.Textbox(label="Session ID"),
                gr.Textbox(label="Question"),
            ],
            outputs=gr.Code(label="Answer", language="json"),
            flagging_mode="never",
        )

    with gr.Tab("Close / Status"):
        with gr.Row():
            gr.Interface(
                fn=close_session,
                inputs=[gr.Textbox(label="Session ID")],
                outputs=gr.Code(label="Receipt", language="json"),
                flagging_mode="never",
            )
        with gr.Row():
            gr.Interface(
                fn=get_sessions,
                inputs=[],
                outputs=gr.Code(label="Active Sessions", language="json"),
                flagging_mode="never",
            )

    with gr.Tab("Fetch Content"):
        gr.Interface(
            fn=fetch_content,
            inputs=[
                gr.Textbox(label="ContentDelivery JSON", lines=5),
                gr.Textbox(label="Canister ID (for canisterQuery, optional)"),
            ],
            outputs=gr.Code(label="Content", language="json"),
            flagging_mode="never",
        )


if __name__ == "__main__":
    simulation = "--simulation" in sys.argv
    if simulation and not os.getenv("IC402_PRIVATE_KEY_HEX"):
        # Auto-init with a throwaway key for demo
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        demo_key = Ed25519PrivateKey.generate().private_bytes_raw().hex()
        _client = client_from_hex(demo_key, "demo-canister", simulation=True)
        print(f"Simulation mode — principal: {_client.principal()}")

    print("MCP endpoint: http://localhost:7861/gradio_api/mcp/sse")
    demo.launch(mcp_server=True, server_port=7861)
