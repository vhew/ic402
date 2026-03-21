"""
ic402 Python SDK — AgentflowClient.

Python parallel of packages/client/src/client.ts.
Handles x402 charge payments and streaming sessions against
ic402-enabled ICP canisters.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass, field
from typing import Any, Optional

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from .exceptions import (
    BudgetExceededError,
    CanisterError,
    PaymentRequiredError,
    PolicyDeniedError,
    SessionClosedError,
)
from .types import (
    BudgetConfig,
    PaymentReceipt,
    PaymentSignature,
    SessionConfig,
    SessionIntent,
    SessionPreferences,
    SessionState,
    Voucher,
)
from .voucher import sign_voucher


# ── Candid field hash helpers ─────────────────────────────────────────────────

def _candid_field_hash(name: str) -> int:
    """Compute the Candid field name hash (hash32)."""
    h = 0
    for c in name:
        h = (h * 223 + ord(c)) & 0xFFFFFFFF
    return h


# Pre-computed hash → field name mapping for ic402 Candid types
_FIELD_NAMES = [
    "network", "token", "recipient", "suggestedDeposit", "expiry",
    "minDeposit", "costPerCall", "description",
    "id", "payer", "deposited", "consumed", "remaining",
    "voucherCount", "status", "openedAt", "lastActivityAt",
    "amount", "sender", "timestamp", "txHash", "sessionId", "refunded",
    "scheme", "nonce", "signature",
    "paymentRequired", "ok", "err", "error", "open", "closed",
]
_HASH_TO_NAME: dict[int, str] = {_candid_field_hash(n): n for n in _FIELD_NAMES}


def _remap_fields(raw: Any) -> Any:
    """Recursively replace hashed Candid field keys (_123456) with readable names."""
    if isinstance(raw, dict):
        out: dict[str, Any] = {}
        for k, v in raw.items():
            clean = k.lstrip("_")
            try:
                num = int(clean)
                readable = _HASH_TO_NAME.get(num, k)
            except ValueError:
                readable = k
            out[readable] = _remap_fields(v)
        return out
    if isinstance(raw, list):
        return [_remap_fields(i) for i in raw]
    return raw


# ── ICP canister interaction ──────────────────────────────────────────────────

def _make_ic_agent(canister_id: str, private_key: Ed25519PrivateKey, network: str) -> Any:
    """Build an ic-py Agent bound to a canister. Returns None if ic-py unavailable."""
    try:
        from ic.agent import Agent
        from ic.client import Client
        from ic.identity import Identity

        raw = private_key.private_bytes_raw()
        identity = Identity(privkey=raw.hex(), type="ed25519")

        ic_url = "https://icp-api.io" if "mainnet" in network or network == "icp:1" else "http://127.0.0.1:4944"
        client = Client(url=ic_url)
        return Agent(identity, client)
    except ImportError:
        return None


def _candid_encode_sig(sig: PaymentSignature) -> dict:
    return {
        "scheme": sig.scheme,
        "network": sig.network,
        "signature": list(sig.signature),
        "sender": sig.sender,
        "nonce": list(sig.nonce),
    }


def _candid_encode_voucher(v: Voucher) -> dict:
    return {
        "sessionId": v.session_id,
        "cumulativeAmount": v.cumulative_amount,
        "sequence": v.sequence,
        "signature": list(v.signature),
    }


def _parse_session_state(raw: dict) -> SessionState:
    status_variant = raw.get("status", {})
    status = list(status_variant.keys())[0] if isinstance(status_variant, dict) else "open"
    return SessionState(
        id=raw["id"],
        deposited=int(raw["deposited"]),
        consumed=int(raw["consumed"]),
        remaining=int(raw["remaining"]),
        voucher_count=int(raw.get("voucherCount", 0)),
        status=status,
        opened_at=int(raw.get("openedAt", 0)),
        last_activity_at=int(raw.get("lastActivityAt", 0)),
    )


def _parse_session_intent(raw: dict) -> SessionIntent:
    return SessionIntent(
        network=raw["network"],
        token=raw["token"],
        recipient=raw["recipient"],
        suggested_deposit=int(raw["suggestedDeposit"]),
        expiry=int(raw["expiry"]),
        min_deposit=int(raw["minDeposit"][0]) if raw.get("minDeposit") else None,
        cost_per_call=int(raw["costPerCall"][0]) if raw.get("costPerCall") else None,
        description=raw["description"][0] if raw.get("description") else None,
    )


def _parse_receipt(raw: dict) -> PaymentReceipt:
    return PaymentReceipt(
        id=raw["id"],
        amount=int(raw["amount"]),
        token=raw["token"],
        sender=raw["sender"],
        recipient=raw["recipient"],
        network=raw["network"],
        timestamp=int(raw["timestamp"]),
        tx_hash=raw["txHash"][0] if raw.get("txHash") else None,
        session_id=raw["sessionId"][0] if raw.get("sessionId") else None,
        refunded=int(raw["refunded"][0]) if raw.get("refunded") else None,
    )


# ── Simulation mode (demo without live canister) ──────────────────────────────

_SIM_SESSIONS: dict[str, dict] = {}


def _sim_call(method: str, args: list) -> dict:
    """Return realistic mock responses matching the example canister."""
    if method == "search":
        query, sig_opt = args[0], args[1] if len(args) > 1 else None
        if not sig_opt:
            return {"paymentRequired": {
                "scheme": "exact", "network": "icp:1",
                "token": "xevnm-gaaaa-aaaar-qafnq-cai",
                "amount": 50_000, "recipient": "sim-canister",
                "nonce": bytes(32), "expiry": int(time.time() * 1e9) + 300_000_000_000,
            }}
        return {"ok": ["result 1", "result 2"]}

    if method == "requestSession":
        return {
            "network": "icp:1", "token": "xevnm-gaaaa-aaaar-qafnq-cai",
            "recipient": "sim-canister", "suggestedDeposit": 1_000_000,
            "minDeposit": [100_000], "expiry": int(time.time() * 1e9) + 300_000_000_000,
            "costPerCall": [1_000], "description": ["Knowledge base session — pay per query"],
        }

    if method == "openSession":
        config = args[0]
        sid = f"sim-sess-{int(time.time())}"
        deposit = config.get("maxDeposit", 1_000_000)
        _SIM_SESSIONS[sid] = {"deposited": deposit, "consumed": 0, "seq": 0}
        return {"ok": {
            "id": sid, "payer": "sim-payer", "deposited": deposit,
            "consumed": 0, "remaining": deposit, "voucherCount": 0,
            "status": {"open": None}, "openedAt": int(time.time() * 1e9),
            "lastActivityAt": int(time.time() * 1e9),
        }}

    if method == "sessionQuery":
        voucher, question = args[0], args[1]
        sid = voucher.get("sessionId", "")
        sess = _SIM_SESSIONS.get(sid)
        if not sess:
            return {"error": "Session not found"}
        cost = 1_000
        sess["consumed"] += cost
        sess["seq"] += 1
        return {"ok": f"Answer to: {question}"}

    if method == "endSession":
        sid = args[0]
        sess = _SIM_SESSIONS.pop(sid, {"consumed": 0, "deposited": 0})
        consumed = sess.get("consumed", 0)
        deposited = sess.get("deposited", 1_000_000)
        return {"ok": {
            "id": f"rcpt-{sid}", "amount": consumed,
            "token": "xevnm-gaaaa-aaaar-qafnq-cai",
            "sender": "sim-payer", "recipient": "sim-canister",
            "network": "icp:1", "timestamp": int(time.time() * 1e9),
            "txHash": [], "sessionId": [sid],
            "refunded": [deposited - consumed],
        }}

    return {"error": f"Unknown method: {method}"}


# ── SessionHandle ─────────────────────────────────────────────────────────────

class SessionHandle:
    """
    Live session handle. Call .call() to make paid requests,
    .close() to settle and refund.
    """

    def __init__(
        self,
        state: SessionState,
        intent: SessionIntent,
        private_key: Ed25519PrivateKey,
        canister_id: str,
        ic_agent: Any,
        simulation: bool,
    ) -> None:
        self._state = state
        self._intent = intent
        self._key = private_key
        self._canister_id = canister_id
        self._ic_agent = ic_agent
        self._simulation = simulation
        self._sequence = 0
        self._consumed = 0
        self._closed = False

    @property
    def id(self) -> str:
        return self._state.id

    @property
    def deposited(self) -> int:
        return self._state.deposited

    @property
    def consumed(self) -> int:
        return self._consumed

    @property
    def remaining(self) -> int:
        return self._state.deposited - self._consumed

    async def call(self, method: str, *args: Any) -> Any:
        """Make a session-gated canister call, signing a cumulative voucher."""
        if self._closed:
            raise SessionClosedError(self.id)

        cost = self._intent.cost_per_call or 1_000
        new_cumulative = self._consumed + cost
        self._sequence += 1

        sig = sign_voucher(self._key, self.id, new_cumulative, self._sequence)
        voucher = Voucher(
            session_id=self.id,
            cumulative_amount=new_cumulative,
            sequence=self._sequence,
            signature=sig,
        )
        # Use typed Candid encoding for sessionQuery (ic-py needs explicit types)
        if method == "sessionQuery" and len(args) == 1 and isinstance(args[0], str):
            raw = self._candid_session_query(method, voucher, args[0])
        else:
            voucher_dict = _candid_encode_voucher(voucher)
            raw = self._raw_call(method, [voucher_dict, *args])

        if "ok" in raw:
            self._consumed = new_cumulative
            return raw["ok"]
        if "error" in raw:
            raise CanisterError(raw["error"])
        return raw

    async def close(self) -> PaymentReceipt:
        """Close the session, settle on-chain, and refund remainder."""
        if self._closed:
            raise SessionClosedError(self.id)
        self._closed = True

        raw = self._candid_text_call("endSession", self.id)

        if "ok" in raw:
            return _parse_receipt(raw["ok"])
        raise CanisterError(f"Failed to close session: {raw}")

    def _candid_text_call(self, method: str, text_arg: str) -> dict:
        """Call a canister method that takes a single Text argument."""
        if self._simulation:
            return _sim_call(method, [text_arg])
        if self._ic_agent is None:
            raise CanisterError("ic-py not available and simulation=False")
        try:
            from ic.candid import encode, Types
            params = [{"type": Types.Text, "value": text_arg}]
            result = self._ic_agent.update_raw(self._canister_id, method, encode(params))
            if isinstance(result, list) and result:
                item = result[0]
                if isinstance(item, dict) and "value" in item:
                    return _remap_fields(item["value"])
                return _remap_fields(item)
            return _remap_fields(result) if isinstance(result, dict) else {}
        except Exception as e:
            raise CanisterError(str(e), e) from e

    def _candid_session_query(self, method: str, voucher: "Voucher", question: str) -> dict:
        """Call sessionQuery with properly typed Candid Voucher record."""
        if self._simulation:
            return _sim_call(method, [_candid_encode_voucher(voucher), question])
        if self._ic_agent is None:
            raise CanisterError("ic-py not available and simulation=False")
        try:
            from ic.candid import encode, Types
            VoucherType = Types.Record({
                "sessionId":        Types.Text,
                "cumulativeAmount": Types.Nat,
                "sequence":         Types.Nat,
                "signature":        Types.Vec(Types.Nat8),
            })
            params = [
                {"type": VoucherType, "value": {
                    "sessionId":        voucher.session_id,
                    "cumulativeAmount": voucher.cumulative_amount,
                    "sequence":         voucher.sequence,
                    "signature":        list(voucher.signature),
                }},
                {"type": Types.Text, "value": question},
            ]
            result = self._ic_agent.update_raw(self._canister_id, method, encode(params))
            if isinstance(result, list) and result:
                item = result[0]
                if isinstance(item, dict) and "value" in item:
                    return _remap_fields(item["value"])
                return _remap_fields(item)
            return _remap_fields(result) if isinstance(result, dict) else {}
        except Exception as e:
            raise CanisterError(str(e), e) from e

    def _raw_call(self, method: str, args: list) -> dict:
        if self._simulation:
            return _sim_call(method, args)
        try:
            from ic.candid import encode
            result = self._ic_agent.update_raw(
                self._canister_id, method, encode(args)
            )
            if isinstance(result, list) and result:
                item = result[0]
                if isinstance(item, dict) and "value" in item:
                    return _remap_fields(item["value"])
                return _remap_fields(item)
            return _remap_fields(result) if isinstance(result, dict) else {}
        except Exception as e:
            raise CanisterError(str(e), e) from e


# ── AgentflowClient ───────────────────────────────────────────────────────────

class AgentflowClient:
    """
    ic402 Python client SDK.

    Handles x402 charge payments and streaming sessions against
    ic402-enabled ICP canisters.

    Args:
        private_key: Ed25519PrivateKey for signing payments and vouchers.
        canister_id:  Default canister principal to call.
        network:      CAIP-2 network identifier (default "icp:1" = mainnet).
        auto_payment: If True, attempt to settle 402s automatically.
        budget:       Client-side spending limits.
        simulation:   If True, return mock responses without a live canister.
    """

    def __init__(
        self,
        private_key: Ed25519PrivateKey,
        canister_id: str,
        network: str = "icp:1",
        auto_payment: bool = False,
        budget: Optional[BudgetConfig] = None,
        simulation: bool = False,
    ) -> None:
        self._key = private_key
        self._canister_id = canister_id
        self._network = network
        self._auto_payment = auto_payment
        self._budget = budget or BudgetConfig()
        self._simulation = simulation
        self._total_spent = 0
        self._ic_agent = None if simulation else _make_ic_agent(canister_id, private_key, network)

    # ── Public API ─────────────────────────────────────────────────────────────

    async def call(
        self,
        method: str,
        *args: Any,
        canister_id: Optional[str] = None,
    ) -> Any:
        """
        Call a canister method, auto-handling 402 PaymentRequired if needed.

        Flow: call → if #paymentRequired → check budget → raise PaymentRequiredError
              (ICRC-2 auto-approval is a TODO — approve externally for now)
        """
        raw = self._raw_call(method, list(args), canister_id)

        if "paymentRequired" in raw:
            req_raw = raw["paymentRequired"]
            from .types import PaymentRequirement
            req = PaymentRequirement(
                scheme=req_raw["scheme"],
                network=req_raw["network"],
                token=req_raw["token"],
                amount=int(req_raw["amount"]),
                recipient=req_raw["recipient"],
                nonce=bytes(req_raw["nonce"]) if isinstance(req_raw["nonce"], list) else req_raw["nonce"],
                expiry=int(req_raw["expiry"]),
            )

            if self._budget.max_per_request and req.amount > self._budget.max_per_request:
                raise BudgetExceededError(req.amount, self._budget.max_per_request, "per-request")

            if self._budget.max_total and self._total_spent + req.amount > self._budget.max_total:
                raise BudgetExceededError(req.amount, self._budget.max_total, "total")

            if not self._auto_payment:
                raise PaymentRequiredError(req)

            # TODO: icrc2_approve for req.amount, then construct PaymentSignature and retry.
            # For MVP, approve ICRC-2 externally and pass the signature manually.
            raise PaymentRequiredError(req)

        if "policyDenied" in raw:
            raise PolicyDeniedError(raw["policyDenied"])

        if "ok" in raw:
            return raw["ok"]

        return raw

    async def request_session(self, canister_id: Optional[str] = None) -> SessionIntent:
        """Get a session offer from the canister."""
        raw = self._raw_call("requestSession", [], canister_id)
        return _parse_session_intent(raw)

    async def open_session(
        self,
        intent: Optional[SessionIntent] = None,
        max_deposit: Optional[int] = None,
        canister_id: Optional[str] = None,
    ) -> SessionHandle:
        """
        Open a streaming session with escrow deposit.

        Flow: requestSession → negotiate deposit → icrc2_approve [TODO] → openSession
        """
        cid = canister_id or self._canister_id

        if intent is None:
            intent = await self.request_session(cid)

        deposit = min(
            max_deposit or intent.suggested_deposit,
            intent.suggested_deposit,
        )
        if intent.min_deposit and deposit < intent.min_deposit:
            deposit = intent.min_deposit

        if self._budget.max_session_deposit and deposit > self._budget.max_session_deposit:
            raise BudgetExceededError(deposit, self._budget.max_session_deposit, "session-deposit")

        # TODO: icrc2_approve for deposit amount before calling openSession.
        # For MVP, the canister's signature verification is stubbed (accepts all sigs).
        pub_bytes = self._key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        stub_sig = PaymentSignature(
            scheme="exact",
            network=self._network,
            signature=bytes(64),
            sender=self.principal(),
            nonce=bytes(32),
        )

        raw = self._candid_open_session(cid, deposit, stub_sig)

        if "err" in raw:
            raise CanisterError(f"Failed to open session: {raw['err']}")

        state = _parse_session_state(raw["ok"])
        return SessionHandle(
            state=state,
            intent=intent,
            private_key=self._key,
            canister_id=cid,
            ic_agent=self._ic_agent,
            simulation=self._simulation,
        )

    def principal(self) -> str:
        """Return the text-encoded principal for the current identity."""
        if self._simulation:
            return "sim-principal-aaa-bbb"
        try:
            from ic.identity import Identity
            raw = self._key.private_bytes_raw()
            identity = Identity(privkey=raw.hex(), type="ed25519")
            return str(identity.sender())
        except Exception:
            return "unknown-principal"

    def public_key_bytes(self) -> bytes:
        """Return the raw 32-byte Ed25519 public key."""
        return self._key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)

    # ── Internal ───────────────────────────────────────────────────────────────

    def _candid_open_session(self, cid: str, deposit: int, sig: "PaymentSignature") -> dict:
        """Call openSession with properly typed Candid records (ic-py requires typed args)."""
        if self._simulation:
            return _sim_call("openSession", [{"maxDeposit": deposit}])
        if self._ic_agent is None:
            raise CanisterError("ic-py not available and simulation=False")
        try:
            from ic.candid import encode, Types

            SessionConfigType = Types.Record({
                "maxDeposit": Types.Nat,
                "autoClose": Types.Bool,
                "idleTimeout": Types.Opt(Types.Int),
            })
            PaymentSigType = Types.Record({
                "scheme": Types.Text,
                "network": Types.Text,
                "signature": Types.Vec(Types.Nat8),
                "sender": Types.Text,
                "nonce": Types.Vec(Types.Nat8),
            })
            params = [
                {"type": SessionConfigType, "value": {
                    "maxDeposit": deposit, "autoClose": True, "idleTimeout": [],
                }},
                {"type": PaymentSigType, "value": {
                    "scheme": sig.scheme,
                    "network": sig.network,
                    "signature": list(sig.signature),
                    "sender": sig.sender,
                    "nonce": list(sig.nonce),
                }},
            ]
            result = self._ic_agent.update_raw(cid, "openSession", encode(params))
            if isinstance(result, list) and result:
                item = result[0]
                if isinstance(item, dict) and "value" in item:
                    return _remap_fields(item["value"])
                return _remap_fields(item)
            return _remap_fields(result) if isinstance(result, dict) else {}
        except Exception as e:
            raise CanisterError(str(e), e) from e

    def _raw_call(self, method: str, args: list, canister_id: Optional[str] = None) -> dict:
        cid = canister_id or self._canister_id
        if self._simulation:
            return _sim_call(method, args)
        if self._ic_agent is None:
            raise CanisterError("ic-py not available and simulation=False")
        try:
            from ic.candid import encode
            # ic-py update_raw returns already-decoded list of {type, value} dicts
            result = self._ic_agent.update_raw(cid, method, encode(args))
            if isinstance(result, list) and result:
                item = result[0]
                if isinstance(item, dict) and "value" in item:
                    return _remap_fields(item["value"])
                return _remap_fields(item)
            return _remap_fields(result) if isinstance(result, dict) else {}
        except Exception as e:
            raise CanisterError(str(e), e) from e


# ── Factory helpers ───────────────────────────────────────────────────────────

def client_from_hex(
    private_key_hex: str,
    canister_id: str,
    network: str = "icp:1",
    simulation: bool = False,
    **kwargs,
) -> AgentflowClient:
    """Construct an AgentflowClient from a hex-encoded Ed25519 private key seed."""
    seed = bytes.fromhex(private_key_hex)
    key = Ed25519PrivateKey.from_private_bytes(seed)
    return AgentflowClient(key, canister_id, network=network, simulation=simulation, **kwargs)


def client_from_env(simulation: bool = False) -> AgentflowClient:
    """
    Construct an AgentflowClient from environment variables:
      IC402_PRIVATE_KEY_HEX  — 32-byte Ed25519 seed as hex
      IC402_CANISTER_ID      — target canister principal
      IC402_NETWORK          — CAIP-2 network (default: icp:1)
    """
    key_hex = os.environ["IC402_PRIVATE_KEY_HEX"]
    canister_id = os.environ["IC402_CANISTER_ID"]
    network = os.environ.get("IC402_NETWORK", "icp:1")
    return client_from_hex(key_hex, canister_id, network=network, simulation=simulation)
