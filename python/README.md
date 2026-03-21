# ic402 Python SDK

Python client library and MCP server for **ic402** — the x402 micropayment protocol for ICP canisters.

ic402 lets you pay-per-call or run streaming sessions against ICP canisters. Two on-chain transactions cover an unlimited number of session calls: one deposit escrow and one settlement+refund. Per-call charges use ICRC-2 approve-then-transfer.

---

## Table of Contents

- [Overview](#overview)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Environment Variables](#environment-variables)
- [Client API Reference](#client-api-reference)
  - [Factory Functions](#factory-functions)
  - [AgentflowClient](#agentflowclient)
  - [SessionHandle](#sessionhandle)
- [Types](#types)
- [Exception Handling](#exception-handling)
- [MCP Server](#mcp-server)
  - [FastMCP Server](#fastmcp-server)
  - [Gradio MCP Server](#gradio-mcp-server)
  - [Claude Desktop Integration](#claude-desktop-integration)
- [Voucher Crypto](#voucher-crypto)
- [Simulation Mode](#simulation-mode)
- [Known Limitations](#known-limitations)

---

## Overview

```
┌────────────────────┐     ICRC-2 approve      ┌──────────────────┐
│  AgentflowClient   │ ─────────────────────►  │  ckUSDC Ledger   │
│  (Python SDK)      │                          │  (ICP canister)  │
│                    │     openSession /         └──────────────────┘
│                    │     sessionQuery /                 ▲
│                    │     endSession                     │
│                    │ ──────────────────────►  ┌─────────┴────────┐
│                    │                          │  Example Canister │
│                    │  Ed25519 vouchers         │  (ic402-enabled)  │
│                    │  (signed off-chain)       └──────────────────┘
└────────────────────┘
```

**Payment flows:**

| Flow | Transactions | Best For |
|------|-------------|----------|
| Per-call charge | 2 on-chain (approve + transfer_from) | Infrequent calls |
| Session (streaming) | 2 on-chain (open + close), 0 per call | Repeated queries |

---

## Installation

```bash
# From the repo root
pip install -e python/

# With dev extras (pytest, ruff)
pip install -e "python/[dev]"
```

**Requirements:** Python ≥ 3.11, ic-py ≥ 1.0.1

**Dependencies installed automatically:**
- `ic-py` — ICP canister interaction
- `cryptography` — Ed25519 key handling
- `cbor2` — voucher serialisation
- `mcp[cli]` — MCP server runtime
- `httpx` — async HTTP for content delivery
- `python-dotenv` — `.env` file loading

---

## Quick Start

### Simulation mode (no live canister required)

```python
import asyncio
from ic402 import client_from_env

async def main():
    # simulation=True returns mock responses — great for development
    client = client_from_env(simulation=True)

    # Check our principal
    print("Identity:", client.principal())

    # Open a session (deposit once, call many times)
    session = await client.open_session()
    print(f"Session {session.id}: deposited={session.deposited}")

    # Make paid calls — vouchers signed automatically
    answer = await session.call("sessionQuery", "explain transformers in one sentence")
    print("Answer:", answer)

    answer2 = await session.call("sessionQuery", "what is ICP?")
    print("Answer 2:", answer2)

    print(f"Consumed: {session.consumed}, Remaining: {session.remaining}")

    # Close and get refund
    receipt = await session.close()
    print(f"Refunded: {receipt.refunded}")

asyncio.run(main())
```

### Live canister (local replica)

```python
import asyncio
from ic402 import client_from_hex

async def main():
    client = client_from_hex(
        private_key_hex="your-32-byte-seed-as-hex",
        canister_id="bkyz2-fmaaa-aaaaa-qaaaq-cai",   # example canister
        network="local",                               # or "icp:1" for mainnet
    )

    # Ask for session pricing first
    intent = await client.request_session()
    print(f"Cost per call: {intent.cost_per_call}")
    print(f"Suggested deposit: {intent.suggested_deposit}")
    print(f"Description: {intent.description}")

    # Open session (requires prior ICRC-2 approval — see Known Limitations)
    session = await client.open_session(intent=intent)
    result = await session.call("sessionQuery", "hello world")
    print(result)
    await session.close()

asyncio.run(main())
```

---

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `IC402_PRIVATE_KEY_HEX` | Yes | — | 32-byte Ed25519 seed as hex string |
| `IC402_CANISTER_ID` | Yes | — | Target canister principal |
| `IC402_NETWORK` | No | `icp:1` | CAIP-2 network (`icp:1` = mainnet, `local` = local replica) |
| `IC402_SIMULATION` | No | `false` | Set to `true` for mock responses |

Copy `python/.env.example` to `python/.env` and fill in values:

```bash
export IC402_PRIVATE_KEY_HEX="0000000000000000000000000000000000000000000000000000000000000001"
export IC402_CANISTER_ID="bkyz2-fmaaa-aaaaa-qaaaq-cai"
export IC402_NETWORK="local"
export IC402_SIMULATION="false"
```

---

## Client API Reference

### Factory Functions

#### `client_from_env(simulation=False) → AgentflowClient`

Construct a client from environment variables (`IC402_PRIVATE_KEY_HEX`, `IC402_CANISTER_ID`, `IC402_NETWORK`).

```python
from ic402 import client_from_env

client = client_from_env()
client_sim = client_from_env(simulation=True)
```

#### `client_from_hex(private_key_hex, canister_id, network="icp:1", simulation=False, **kwargs) → AgentflowClient`

Construct a client from a hex-encoded Ed25519 private key seed.

```python
from ic402 import client_from_hex

client = client_from_hex(
    private_key_hex="deadbeef..." * 8,    # 32 bytes = 64 hex chars
    canister_id="bkyz2-fmaaa-aaaaa-qaaaq-cai",
    network="local",
    simulation=False,
)
```

---

### AgentflowClient

The main client class. Handles identity, canister calls, payment flows, and session lifecycle.

```python
from ic402 import AgentflowClient, BudgetConfig
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

key = Ed25519PrivateKey.generate()
client = AgentflowClient(
    private_key=key,
    canister_id="bkyz2-fmaaa-aaaaa-qaaaq-cai",
    network="icp:1",           # CAIP-2 network identifier
    auto_payment=False,        # auto-settle 402s (ICRC-2 approve is TODO)
    budget=BudgetConfig(       # client-side spending limits
        max_per_request=100_000,
        max_session_deposit=5_000_000,
        max_total=50_000_000,
    ),
    simulation=False,
)
```

#### `await client.call(method, *args, canister_id=None) → Any`

Call a canister method. Raises `PaymentRequiredError` if the canister requires payment and `auto_payment=False`.

```python
try:
    result = await client.call("search", "ICP documentation")
except PaymentRequiredError as e:
    print(f"Cost: {e.requirement.amount} {e.requirement.token}")
```

#### `await client.request_session(canister_id=None) → SessionIntent`

Fetch a session offer from the canister — shows pricing before committing funds.

```python
intent = await client.request_session()
print(intent.suggested_deposit)   # e.g. 1_000_000
print(intent.cost_per_call)       # e.g. 1_000
print(intent.description)         # human-readable description
```

#### `await client.open_session(intent=None, max_deposit=None, canister_id=None) → SessionHandle`

Open a streaming session. Deposits funds into escrow; all subsequent calls are paid via signed vouchers.

```python
# Auto-fetch intent and use suggested deposit
session = await client.open_session()

# Cap deposit manually
session = await client.open_session(max_deposit=500_000)

# Reuse a previously fetched intent
intent = await client.request_session()
session = await client.open_session(intent=intent, max_deposit=200_000)
```

#### `client.principal() → str`

Return the text-encoded ICP principal for the current identity.

```python
print(client.principal())  # e.g. "2vxsx-fae" or "sim-principal-aaa-bbb" in simulation
```

#### `client.public_key_bytes() → bytes`

Return the raw 32-byte Ed25519 public key.

---

### SessionHandle

A live session. Signs vouchers automatically on each call.

```python
# Preferred: use as async context manager
async with await client.open_session() as session:
    result = await session.call("sessionQuery", "my question")
# session.close() called automatically on exit
```

#### Properties

| Property | Type | Description |
|----------|------|-------------|
| `session.id` | `str` | Unique session identifier |
| `session.deposited` | `int` | Total escrowed amount (base units) |
| `session.consumed` | `int` | Running total of voucher amounts |
| `session.remaining` | `int` | `deposited - consumed` |

#### `await session.call(method, *args) → Any`

Make a session-gated canister call. Signs a cumulative Ed25519 voucher and sends it with the request. Raises `SessionClosedError` if the session is already closed.

```python
# sessionQuery is the standard session method
answer = await session.call("sessionQuery", "what is DeFi?")

# Other session methods work too
result = await session.call("someSessionMethod", arg1, arg2)
```

#### `await session.close() → PaymentReceipt`

Close the session, settle the final voucher on-chain, and receive a refund of unused funds.

```python
receipt = await session.close()
print(f"Paid: {receipt.amount}")
print(f"Refunded: {receipt.refunded}")
print(f"Receipt ID: {receipt.id}")
```

---

## Types

All types are dataclasses and importable from `ic402`:

```python
from ic402 import (
    SessionIntent, SessionState, SessionConfig,
    Voucher, PaymentRequirement, PaymentSignature, PaymentReceipt,
    BudgetConfig, SpendingPolicy, SessionPreferences,
    ContentDelivery, AccessGrant, ContentRef,
    DeliveryInline, DeliveryHttpUrl, DeliveryCanisterQuery, DeliveryAssetCanister,
)
```

### Core Types

#### `SessionIntent`
Canister's session offer, returned by `request_session()`.

| Field | Type | Description |
|-------|------|-------------|
| `network` | `str` | CAIP-2 network (e.g. `"icp:1"`) |
| `token` | `str` | Ledger canister principal |
| `recipient` | `str` | Canister principal that receives payment |
| `suggested_deposit` | `int` | Recommended escrow amount |
| `expiry` | `int` | Offer expiry (nanosecond timestamp) |
| `min_deposit` | `int?` | Minimum acceptable deposit |
| `cost_per_call` | `int?` | Fee deducted per session call |
| `description` | `str?` | Human-readable service description |

#### `SessionState`
Live session accounting, returned by `open_session()`.

| Field | Type | Description |
|-------|------|-------------|
| `id` | `str` | Unique session ID |
| `deposited` | `int` | Total escrowed |
| `consumed` | `int` | Vouchers redeemed |
| `remaining` | `int` | Available budget |
| `voucher_count` | `int` | Number of vouchers submitted |
| `status` | `"open" \| "closing" \| "closed" \| "expired"` | Session status |
| `opened_at` | `int` | Nanosecond timestamp |
| `last_activity_at` | `int` | Nanosecond timestamp |

#### `PaymentRequirement`
402 response from a canister requiring payment.

| Field | Type | Description |
|-------|------|-------------|
| `scheme` | `str` | `"exact"` |
| `network` | `str` | CAIP-2 network |
| `token` | `str` | Ledger canister principal |
| `amount` | `int` | Required amount in base units |
| `recipient` | `str` | Canister that receives payment |
| `nonce` | `bytes` | 32-byte one-time nonce |
| `expiry` | `int` | Nanosecond expiry timestamp |

#### `PaymentReceipt`
Settlement receipt returned by `session.close()`.

| Field | Type | Description |
|-------|------|-------------|
| `id` | `str` | Receipt ID |
| `amount` | `int` | Amount consumed |
| `token` | `str` | Ledger principal |
| `sender` | `str` | Payer principal |
| `recipient` | `str` | Canister principal |
| `network` | `str` | CAIP-2 network |
| `timestamp` | `int` | Nanosecond timestamp |
| `tx_hash` | `str?` | On-chain transaction hash |
| `session_id` | `str?` | Associated session ID |
| `refunded` | `int?` | Amount refunded to payer |

#### `BudgetConfig`
Client-side spending limits (enforced locally, not on-chain).

```python
BudgetConfig(
    max_per_request=100_000,      # max cost for a single call
    max_per_day=10_000_000,       # daily cap (tracked in-memory)
    max_total=50_000_000,         # lifetime cap
    max_session_deposit=5_000_000, # cap on escrow per session
    alert_threshold=1_000_000,    # (reserved for future alerting)
)
```

#### `Voucher`
Ed25519-signed cumulative payment voucher (internal, rarely needed directly).

| Field | Type | Description |
|-------|------|-------------|
| `session_id` | `str` | Associated session |
| `cumulative_amount` | `int` | Cumulative total including this call |
| `sequence` | `int` | Monotonically increasing call counter |
| `signature` | `bytes` | Ed25519 signature over CBOR payload |

---

## Exception Handling

```python
from ic402 import (
    AgentflowError,          # base exception
    PaymentRequiredError,    # canister returned #paymentRequired
    BudgetExceededError,     # client-side budget would be breached
    PolicyDeniedError,       # canister policy engine rejected the call
    SessionError,            # base for session errors
    SessionClosedError,      # call on an already-closed session
    InsufficientDepositError, # session budget exhausted
    InvalidVoucherError,     # voucher rejected by canister
    CanisterError,           # transport or decoding error
)
```

### Example: handle all payment errors

```python
from ic402 import (
    PaymentRequiredError, BudgetExceededError, SessionClosedError,
    CanisterError, AgentflowError,
)

try:
    result = await session.call("sessionQuery", "hello")

except PaymentRequiredError as e:
    # Canister wants payment — inspect the requirement
    req = e.requirement
    print(f"Need {req.amount} {req.token} on {req.network}")

except BudgetExceededError as e:
    # Client-side budget guard fired before sending the call
    print(f"Budget exceeded: {e.requested} > {e.limit} ({e.kind})")

except SessionClosedError as e:
    print(f"Session already closed: {e}")

except CanisterError as e:
    # Transport / Candid decoding / canister trap
    print(f"Canister error: {e}")
    if e.__cause__:
        print(f"  Caused by: {e.__cause__}")

except AgentflowError as e:
    # Catch-all for any ic402 error
    print(f"ic402 error: {e}")
```

---

## MCP Server

The ic402 MCP server exposes canister payment tools to any MCP-compatible AI client (Claude Desktop, Cursor, Claude Code, etc.).

### FastMCP Server

The production MCP server uses [FastMCP](https://github.com/jlowin/fastmcp) and communicates via stdio.

**Run in dev mode (with inspector):**
```bash
cd python
mcp dev mcp_server/server.py
```

**Run directly:**
```bash
IC402_PRIVATE_KEY_HEX="..." IC402_CANISTER_ID="..." ic402-mcp
```

**Run with simulation:**
```bash
IC402_SIMULATION=true ic402-mcp
```

#### Available MCP Tools

| Tool | Description |
|------|-------------|
| `setup_identity` | Initialise client with Ed25519 key + canister ID |
| `call_canister` | Call a canister method; handles 402 responses |
| `request_session_intent` | Preview session pricing before committing funds |
| `open_session` | Open session with escrow deposit; returns `session_id` |
| `session_call` | Call via open session (voucher signed automatically) |
| `close_session` | Settle on-chain and refund unused funds |
| `fetch_content` | Fetch content from a `ContentDelivery` response |
| `get_session_status` | Check balance/status of open sessions |
| `approve_icrc2` | [Stub] Returns the dfx command to approve ICRC-2 manually |

#### Tool Reference

##### `setup_identity`
```
private_key_hex: str    — 64-char hex Ed25519 seed
canister_id: str        — ICP canister principal
network: str            — CAIP-2 (default: "icp:1")
simulation: bool        — mock mode (default: false)
```

##### `call_canister`
```
method: str             — canister method name
args: list              — method arguments (JSON array)
canister_id: str?       — override default canister
```

##### `request_session_intent`
```
canister_id: str?       — override default canister
```

##### `open_session`
```
max_deposit: int?       — cap on escrowed amount
canister_id: str?       — override default canister
→ returns session_id: str
```

##### `session_call`
```
session_id: str         — from open_session
method: str             — e.g. "sessionQuery"
args: list              — e.g. ["what is ICP?"]
→ returns result + consumed + remaining
```

##### `close_session`
```
session_id: str         — from open_session
→ returns consumed + refunded amounts
```

##### `fetch_content`
```
delivery: str           — ContentDelivery as JSON string
canister_id: str?       — required for canisterQuery delivery
```

##### `get_session_status`
```
session_id: str?        — if omitted, lists all open sessions
```

---

### Gradio MCP Server

An alternative MCP server built on Gradio, useful for visual demos and SSE-based MCP clients.

```bash
cd python
python gradio_mcp.py
```

Starts at `http://localhost:7861`. MCP endpoint: `http://localhost:7861/gradio_api/mcp/sse`

The Gradio server exposes the same 5 core tools (`setup_identity`, `request_session_intent`, `open_session`, `session_query`, `get_sessions`) as a chat-friendly Gradio interface.

---

### Claude Desktop Integration

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS):

```json
{
  "mcpServers": {
    "ic402": {
      "command": "ic402-mcp",
      "env": {
        "IC402_PRIVATE_KEY_HEX": "your-64-char-hex-seed",
        "IC402_CANISTER_ID": "bkyz2-fmaaa-aaaaa-qaaaq-cai",
        "IC402_NETWORK": "icp:1"
      }
    }
  }
}
```

For local development against a local replica:

```json
{
  "mcpServers": {
    "ic402-local": {
      "command": "ic402-mcp",
      "env": {
        "IC402_PRIVATE_KEY_HEX": "your-64-char-hex-seed",
        "IC402_CANISTER_ID": "bkyz2-fmaaa-aaaaa-qaaaq-cai",
        "IC402_NETWORK": "local",
        "IC402_SIMULATION": "false"
      }
    }
  }
}
```

---

## Voucher Crypto

Low-level voucher utilities are exposed for advanced use cases:

```python
from ic402 import sign_voucher, verify_voucher, encode_voucher_payload
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

key = Ed25519PrivateKey.generate()

# Sign a voucher (done automatically by SessionHandle.call())
signature = sign_voucher(
    private_key=key,
    session_id="sess-abc123",
    cumulative_amount=3_000,
    sequence=3,
)

# Verify a voucher signature
public_key = key.public_key()
is_valid = verify_voucher(
    public_key=public_key,
    session_id="sess-abc123",
    cumulative_amount=3_000,
    sequence=3,
    signature=signature,
)
```

**Voucher payload format:** CBOR-encoded map with keys `session_id`, `cumulative_amount`, `sequence`. Signed with Ed25519. Cumulative amounts are monotonically increasing — the canister rejects any voucher with a lower or equal cumulative amount than the last accepted one, preventing replay attacks.

---

## Simulation Mode

Enable with `simulation=True` (or `IC402_SIMULATION=true`) to get realistic mock responses without a live ICP node or canister.

Simulated flows:
- `requestSession` → returns a session intent with 1,000 cost/call, 1,000,000 suggested deposit
- `openSession` → creates an in-memory session
- `sessionQuery` → deducts cost and returns `"Answer to: <question>"`
- `endSession` → returns a receipt with consumed + refunded amounts
- `call("search", ...)` → returns `#paymentRequired` on first call, `["result 1", "result 2"]` with a signature

Simulation state is process-local and resets between runs.

---

## Known Limitations

| Limitation | Status |
|-----------|--------|
| ICRC-2 `approve` must be done manually (dfx or ic-py directly) before `open_session` or paid `call_canister` | Planned for next release |
| `close_session` refund may fail with `InsufficientFunds` if the canister doesn't subtract the transfer fee from the refund amount | Bug in `Gateway.mo` — workaround: ignore the error, funds are still accounted correctly |
| `auto_payment=True` does not yet auto-approve ICRC-2 | Planned — currently raises `PaymentRequiredError` |
| Session concurrency is limited by canister policy (`maxConcurrentSessions`) | Configurable in `main.mo` |
| Content delivery via `canisterQuery` chunks is not verified with HMAC | Planned |
| `BudgetConfig.max_per_day` is tracked in-memory and resets on restart | By design for MVP |

---

## Project Structure

```
python/
├── ic402/
│   ├── __init__.py        # Package exports and version
│   ├── client.py          # AgentflowClient + SessionHandle
│   ├── types.py           # Candid-mirrored Python dataclasses
│   ├── exceptions.py      # Typed exception hierarchy
│   └── voucher.py         # Ed25519 + CBOR voucher signing/verification
├── mcp_server/
│   └── server.py          # FastMCP server (ic402-mcp entry point)
├── gradio_mcp.py          # Gradio MCP server (SSE endpoint)
├── pyproject.toml         # Package config + dependencies
└── .env.example           # Environment variable template
```

---

## License

Apache 2.0 — see root `LICENSE`.
