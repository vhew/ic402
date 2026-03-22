"""
ic402 Python SDK — full demonstration

Shows every feature of the SDK end-to-end in simulation mode.

Run:
    pip install -e python/
    python python/examples/demo.py
"""

import asyncio
import json
import time
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from ic402 import (
    client_from_hex,
    PaymentRequiredError,
    BudgetExceededError,
)
from ic402.voucher import encode_voucher_payload, sign_voucher, verify_voucher
from ic402.types import (
    Voucher,
    ContentDelivery,
    ContentRef,
    AccessGrant,
    DeliveryInline,
)

# ── ANSI colours ──────────────────────────────────────────────────────────────

BOLD  = "\033[1m"
DIM   = "\033[2m"
GREEN = "\033[32m"
CYAN  = "\033[36m"
YELLOW= "\033[33m"
RED   = "\033[31m"
RESET = "\033[0m"

def header(title: str) -> None:
    print(f"\n{BOLD}{CYAN}{'─' * 56}{RESET}")
    print(f"{BOLD}{CYAN}  {title}{RESET}")
    print(f"{BOLD}{CYAN}{'─' * 56}{RESET}")

def ok(msg: str)   -> None: print(f"  {GREEN}✓{RESET}  {msg}")
def info(msg: str) -> None: print(f"  {DIM}→{RESET}  {msg}")
def warn(msg: str) -> None: print(f"  {YELLOW}!{RESET}  {msg}")
def err(msg: str)  -> None: print(f"  {RED}✗{RESET}  {msg}")


# ── 1. Identity & client setup ────────────────────────────────────────────────

def demo_identity() -> tuple:
    header("1. Identity & Client Setup")

    private_key = Ed25519PrivateKey.generate()
    key_hex = private_key.private_bytes_raw().hex()

    client = client_from_hex(
        key_hex,
        canister_id="rrkah-fqaaa-aaaaa-aaaaq-cai",
        network="icp:1",
        simulation=True,
    )

    ok(f"Ed25519 key generated:  {key_hex[:16]}...{key_hex[-8:]}")
    ok(f"Principal:              {client.principal()}")
    ok(f"Public key (32 bytes):  {client.public_key_bytes().hex()[:32]}...")
    info("Simulation mode — no live canister needed")

    return client, private_key


# ── 2. Charge flow (x402) ─────────────────────────────────────────────────────

async def demo_charge_flow(client) -> None:
    header("2. Charge Flow  (x402 — pay per request)")

    info("Calling search() without payment...")
    try:
        await client.call("search", "machine learning")
    except PaymentRequiredError as e:
        req = e.requirement
        ok(f"Got 402 PaymentRequired:")
        info(f"  amount:    {req.amount:,} (0.05 ckUSDC)")
        info(f"  token:     {req.token}")
        info(f"  network:   {req.network}")
        info(f"  recipient: {req.recipient}")
        info(f"  nonce:     {req.nonce.hex()[:16]}...")
        warn("ICRC-2 approval not yet wired — use session flow for now")


# ── 3. Budget guard ───────────────────────────────────────────────────────────

async def demo_budget_guard() -> None:
    header("3. Budget Guard  (client-side spending limits)")

    from ic402 import BudgetConfig
    from ic402.client import client_from_hex

    private_key = Ed25519PrivateKey.generate()
    stingy_client = client_from_hex(
        private_key.private_bytes_raw().hex(),
        canister_id="rrkah-fqaaa-aaaaa-aaaaq-cai",
        simulation=True,
        budget=BudgetConfig(max_per_request=10_000),   # only allows 0.01 ckUSDC
    )

    info("Budget set: max_per_request = 10,000 (canister charges 50,000)")
    try:
        await stingy_client.call("search", "expensive query")
    except PaymentRequiredError as e:
        req = e.requirement
        ok(f"Got 402 — amount {req.amount:,} exceeds budget, raising PaymentRequiredError")
    except BudgetExceededError as e:
        ok(f"BudgetExceededError raised before even calling canister: {e}")


# ── 4. Voucher signing ────────────────────────────────────────────────────────

def demo_voucher_signing(private_key: Ed25519PrivateKey) -> None:
    header("4. Voucher Signing  (Ed25519 + CBOR)")

    session_id     = "sess-demo-001"
    cumulative     = 3_000
    sequence       = 3

    payload = encode_voucher_payload(session_id, cumulative, sequence)
    ok(f"CBOR payload ({len(payload)} bytes): {payload.hex()}")
    info("  Breakdown: 0x83=array(3) | text(session_id) | uint(cumulative) | uint(seq)")

    sig = sign_voucher(private_key, session_id, cumulative, sequence)
    ok(f"Ed25519 signature (64 bytes): {sig.hex()[:32]}...")

    voucher = Voucher(
        session_id=session_id,
        cumulative_amount=cumulative,
        sequence=sequence,
        signature=sig,
    )
    valid = verify_voucher(private_key.public_key(), voucher)
    ok(f"Signature verification: {'PASS' if valid else 'FAIL'}")

    # Show tampered voucher is rejected
    bad_voucher = Voucher(session_id, cumulative + 1, sequence, sig)
    invalid = verify_voucher(private_key.public_key(), bad_voucher)
    ok(f"Tampered voucher rejected: {'PASS' if not invalid else 'FAIL'}")


# ── 5. Session flow (escrow + streaming vouchers) ─────────────────────────────

async def demo_session_flow(client) -> None:
    header("5. Session Flow  (escrow + cumulative vouchers)")

    # Step 1: Get pricing offer
    info("Requesting session intent from canister...")
    intent = await client.request_session()
    ok(f"Session offer received:")
    info(f"  suggested_deposit: {intent.suggested_deposit:,} (1 ckUSDC)")
    info(f"  min_deposit:       {intent.min_deposit:,}")
    info(f"  cost_per_call:     {intent.cost_per_call:,} (0.001 ckUSDC)")
    info(f"  description:       {intent.description}")

    # Step 2: Open session
    info("\nOpening session with 500,000 deposit (0.5 ckUSDC)...")
    session = await client.open_session(intent, max_deposit=500_000)
    ok(f"Session opened:  {session.id}")
    info(f"  deposited:  {session.deposited:,}")
    info(f"  remaining:  {session.remaining:,}")

    # Step 3: Make paid calls — vouchers signed automatically
    questions = [
        "What is the Internet Computer Protocol?",
        "How do threshold ECDSA signatures work?",
        "What makes ICP unique for AI agents?",
        "Explain ICRC-2 token standard",
        "Why are sessions 5000x cheaper than per-request charges?",
    ]

    print()
    for q in questions:
        t0 = time.perf_counter()
        answer = await session.call("sessionQuery", q)
        elapsed = (time.perf_counter() - t0) * 1000
        ok(f"[voucher #{session._sequence}]  {q}")
        info(f"  → {answer}")
        info(f"  consumed={session.consumed:,}  remaining={session.remaining:,}  ({elapsed:.1f}ms)")
        print()

    # Step 4: Close and settle
    info("Closing session — settling on-chain, refunding remainder...")
    receipt = await session.close()
    ok(f"Session closed:")
    info(f"  receipt_id:  {receipt.id}")
    info(f"  consumed:    {receipt.amount:,} ({receipt.amount / 1_000_000:.6f} ckUSDC)")
    info(f"  refunded:    {receipt.refunded:,} ({receipt.refunded / 1_000_000:.6f} ckUSDC)")
    info(f"  5 calls for {receipt.amount / 1_000_000:.4f} ckUSDC total  🎯")


# ── 6. Content delivery types ─────────────────────────────────────────────────

def demo_content_types() -> None:
    header("6. Content Delivery Types  (new in ic402)")

    grant = AccessGrant(
        grant_id="grant-001",
        content_ref=ContentRef(
            id="doc-transformers",
            mime_type="text/markdown",
            size_bytes=1024,
        ),
        grantee="sim-principal-aaa-bbb",
        receipt_id="rcpt-1",
        issued_at=int(time.time() * 1e9),
        expires_at=int(time.time() * 1e9) + 3_600_000_000_000,
        hmac=b"\xde\xad\xbe\xef" * 8,
    )

    # Inline delivery
    content = b"# Transformers\n\nAttention is all you need."
    delivery = ContentDelivery(
        grant=grant,
        delivery=DeliveryInline(data=content),
    )

    ok(f"AccessGrant created:")
    info(f"  grant_id:    {grant.grant_id}")
    info(f"  content_id:  {grant.content_ref.id}")
    info(f"  mime_type:   {grant.content_ref.mime_type}")
    info(f"  hmac:        {grant.hmac.hex()}")
    ok(f"ContentDelivery (inline):")
    info(f"  {delivery.delivery.data.decode()!r}")

    # Show all 4 delivery methods
    from ic402.types import DeliveryHttpUrl, DeliveryAssetCanister, DeliveryCanisterQuery
    methods = [
        ("inline",         "bytes embedded in response"),
        ("httpUrl",        "https://example.com/content/doc-001.md"),
        ("assetCanister",  "canister rrkah-fqaaa.../docs/transformers.md"),
        ("canisterQuery",  "getChunk(grant, chunkIndex) × N calls"),
    ]
    print()
    ok("All 4 delivery methods supported by fetch_content:")
    for name, desc in methods:
        info(f"  {name:<18} {desc}")


# ── Main ──────────────────────────────────────────────────────────────────────

async def main() -> None:
    print(f"\n{BOLD}ic402 Python SDK — Full Demo{RESET}")
    print(f"{DIM}Simulation mode — no ICP node required{RESET}\n")

    client, private_key = demo_identity()

    await demo_charge_flow(client)
    await demo_budget_guard()
    demo_voucher_signing(private_key)
    await demo_session_flow(client)
    demo_content_types()

    print(f"\n{BOLD}{GREEN}{'─' * 56}{RESET}")
    print(f"{BOLD}{GREEN}  All demos complete.{RESET}")
    print(f"{BOLD}{GREEN}{'─' * 56}{RESET}\n")


if __name__ == "__main__":
    asyncio.run(main())
