"""
ic402 Python SDK — end-to-end demo (simulation mode).

Demonstrates the full payment flow without a live ICP canister.

Run:
    pip install -e python/
    python python/examples/demo.py
"""

import asyncio
from ic402 import client_from_hex, PaymentRequiredError

# Generate a random key for the demo (in production, load from secure storage)
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
DEMO_KEY = Ed25519PrivateKey.generate()
DEMO_KEY_HEX = DEMO_KEY.private_bytes_raw().hex()

CANISTER_ID = "example-canister-id"  # replace with real principal


async def demo_charge_flow(client):
    print("\n── Charge flow (x402) ──────────────────────────────")
    print("Calling search() without payment...")
    try:
        await client.call("search", "machine learning")
    except PaymentRequiredError as e:
        req = e.requirement
        print(f"  Got 402: {req.amount} {req.token} on {req.network}")
        print("  (ICRC-2 approve + retry not yet implemented — use session flow)")


async def demo_session_flow(client):
    print("\n── Session flow (escrow + vouchers) ────────────────")

    # 1. See pricing
    intent = await client.request_session()
    print(f"  Session offer: deposit={intent.suggested_deposit}, cost_per_call={intent.cost_per_call}")
    print(f"  Description: {intent.description}")

    # 2. Open session
    session = await client.open_session(intent)
    print(f"  Opened session: {session.id}")
    print(f"  Deposited: {session.deposited}, remaining: {session.remaining}")

    # 3. Make paid calls (vouchers signed automatically)
    questions = [
        "What is the Internet Computer?",
        "Explain threshold ECDSA",
        "How do ICRC-2 sessions work?",
    ]
    for q in questions:
        answer = await session.call("sessionQuery", q)
        print(f"  [{session._sequence}] Q: {q!r}")
        print(f"       A: {answer!r}  (consumed={session.consumed}, remaining={session.remaining})")

    # 4. Close and get refund
    receipt = await session.close()
    print(f"\n  Session closed.")
    print(f"  Receipt: consumed={receipt.amount}, refunded={receipt.refunded}")


async def main():
    print("ic402 Python SDK — demo")
    print(f"Identity: using generated key (sim mode)")

    client = client_from_hex(
        DEMO_KEY_HEX,
        CANISTER_ID,
        simulation=True,   # remove this to hit a real canister
    )
    print(f"Principal: {client.principal()}")

    await demo_charge_flow(client)
    await demo_session_flow(client)

    print("\nDone.")


if __name__ == "__main__":
    asyncio.run(main())
