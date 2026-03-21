"""
agentflow Python SDK — Ed25519 voucher signing.

The CBOR encoding matches packages/client/src/voucher.ts exactly:
  encodeVoucherPayload(sessionId, cumulativeAmount, sequence)
  → 0x83 array(3) | text(sessionId) | uint(cumulativeAmount) | uint(sequence)
"""

from __future__ import annotations

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)

from .types import Voucher


def _cbor_major(major: int, length: int) -> bytes:
    """Encode a CBOR major-type header, matching the TS encodeCborMajor function."""
    base = major << 5
    if length < 24:
        return bytes([base | length])
    elif length < 256:
        return bytes([base | 24, length])
    elif length < 65536:
        return bytes([base | 25, (length >> 8) & 0xFF, length & 0xFF])
    else:
        return bytes([
            base | 26,
            (length >> 24) & 0xFF,
            (length >> 16) & 0xFF,
            (length >> 8) & 0xFF,
            length & 0xFF,
        ])


def encode_voucher_payload(session_id: str, cumulative_amount: int, sequence: int) -> bytes:
    """
    CBOR-encode a voucher payload for signing.

    Produces identical bytes to the TypeScript encodeVoucherPayload() in
    packages/client/src/voucher.ts.

    Example:
      encode_voucher_payload("sess-1", 1000, 3)
      == bytes([0x83, 0x66, 0x73,0x65,0x73,0x73,0x2d,0x31, 0x19,0x03,0xe8, 0x03])
    """
    session_bytes = session_id.encode("utf-8")

    return (
        b"\x83"                                         # array(3)
        + _cbor_major(3, len(session_bytes))            # text string header
        + session_bytes                                 # text string bytes
        + _cbor_major(0, cumulative_amount)             # uint: cumulativeAmount
        + _cbor_major(0, sequence)                      # uint: sequence
    )


def sign_voucher(
    private_key: Ed25519PrivateKey,
    session_id: str,
    cumulative_amount: int,
    sequence: int,
) -> bytes:
    """Sign a cumulative voucher payload with Ed25519."""
    payload = encode_voucher_payload(session_id, cumulative_amount, sequence)
    return private_key.sign(payload)


def verify_voucher(public_key: Ed25519PublicKey, voucher: Voucher) -> bool:
    """Verify a voucher signature. Returns False instead of raising on invalid sig."""
    payload = encode_voucher_payload(
        voucher.session_id, voucher.cumulative_amount, voucher.sequence
    )
    try:
        public_key.verify(voucher.signature, payload)
        return True
    except Exception:
        return False
