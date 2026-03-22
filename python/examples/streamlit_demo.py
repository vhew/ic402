"""
ic402 Python SDK — Interactive Streamlit Demo

Run:
    cd python
    .venv/bin/streamlit run examples/streamlit_demo.py
"""

import asyncio
import sys
import time
import os

import streamlit as st
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from ic402 import client_from_hex, PaymentRequiredError, BudgetExceededError, BudgetConfig
from ic402.voucher import encode_voucher_payload, sign_voucher, verify_voucher
from ic402.types import Voucher

# ── Page config ───────────────────────────────────────────────────────────────

st.set_page_config(
    page_title="ic402 SDK Demo",
    page_icon="⚡",
    layout="wide",
    initial_sidebar_state="expanded",
)

# ── Session state ─────────────────────────────────────────────────────────────

for k, v in {
    "client": None, "private_key": None, "key_hex": None,
    "session_handle": None, "vouchers": [], "log": [],
    "receipt": None, "identity_set": False,
}.items():
    if k not in st.session_state:
        st.session_state[k] = v


def log(msg: str, kind: str = "info"):
    st.session_state.log.append((kind, msg))


def run(coro):
    return asyncio.run(coro)


# ── Sidebar ───────────────────────────────────────────────────────────────────

with st.sidebar:
    st.title("⚡ ic402 SDK")
    st.caption("Autonomous payments for ICP canisters")
    st.divider()

    st.subheader("Identity")
    use_generated = st.toggle("Generate random key", value=True)

    if use_generated:
        if st.button("New Key", use_container_width=True):
            key = Ed25519PrivateKey.generate()
            st.session_state.private_key = key
            st.session_state.key_hex = key.private_bytes_raw().hex()
            st.session_state.client = None
            st.session_state.identity_set = False

        if not st.session_state.key_hex:
            key = Ed25519PrivateKey.generate()
            st.session_state.private_key = key
            st.session_state.key_hex = key.private_bytes_raw().hex()

        st.code(st.session_state.key_hex[:32] + "...", language=None)
    else:
        custom_hex = st.text_input("Private key hex (64 chars)", type="password")
        if custom_hex and len(custom_hex) == 64:
            st.session_state.key_hex = custom_hex
            st.session_state.private_key = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(custom_hex))

    canister_id = st.text_input("Canister ID", value="rrkah-fqaaa-aaaaa-aaaaq-cai")
    simulation = st.toggle("Simulation mode", value=True)

    if st.button("Setup Identity", type="primary", use_container_width=True):
        if st.session_state.key_hex:
            st.session_state.client = client_from_hex(
                st.session_state.key_hex, canister_id, simulation=simulation
            )
            st.session_state.identity_set = True
            st.session_state.vouchers = []
            st.session_state.receipt = None
            st.session_state.session_handle = None
            log(f"Identity ready — principal: {st.session_state.client.principal()}", "ok")
            st.success("Identity ready!")

    if st.session_state.identity_set and st.session_state.client:
        st.divider()
        c = st.session_state.client
        st.subheader("Status")
        st.text(f"Principal\n{c.principal()}")
        st.text(f"Mode\n{'Simulation' if simulation else 'Live'}")

        if st.session_state.session_handle:
            h = st.session_state.session_handle
            st.divider()
            st.subheader("Active Session")
            pct = h.consumed / h.deposited if h.deposited else 0
            st.progress(pct, text=f"{pct*100:.1f}% consumed")
            st.metric("Remaining", f"{h.remaining:,}", delta=f"-{h.consumed:,}", delta_color="inverse")


# ── Main ──────────────────────────────────────────────────────────────────────

st.title("ic402 — Autonomous ICP Payments")
st.caption("A Python library for autonomous micropayments — install it, call paid APIs, pay per use. No wallet UI, no human in the loop.")

col_a, col_b, col_c = st.columns(3)
with col_a:
    st.info("**Install**\n```bash\npip install ic402\n```")
with col_b:
    st.info("**Import**\n```python\nfrom ic402 import client_from_hex\n```")
with col_c:
    st.info("**Call a paid API**\n```python\nawait client.open_session()\n```")

with st.expander("Show me the actual code a data scientist would write"):
    st.code("""
from ic402 import client_from_hex

# 1. Create a client (works in any Python script or Jupyter notebook)
client = client_from_hex(
    private_key_hex="your-ed25519-key",
    canister_id="rrkah-fqaaa-aaaaa-aaaaq-cai",
)

# 2. Open a session — deposit once, call many times
session = await client.open_session()

# 3. Call a paid ICP service (voucher signed automatically)
answer = await session.call("sessionQuery", "explain transformers")
print(answer)

# 4. Close and get refund on unused funds
receipt = await session.close()
print(f"Spent: {receipt.amount} ckUSDC, refunded: {receipt.refunded}")
""", language="python")

st.divider()

if not st.session_state.identity_set:
    st.info("Set up your identity in the sidebar to try the interactive demo below.")

tab1, tab2, tab3, tab4 = st.tabs([
    "Charge Flow", "Voucher Signing", "Session Flow", "Activity Log"
])

# ── Tab 1: Charge Flow ────────────────────────────────────────────────────────

with tab1:
    st.subheader("x402 — Pay Per Request")
    st.write("Each request returns **402 Payment Required** until payment is provided. Good for infrequent calls.")

    col1, col2 = st.columns([2, 1])
    with col1:
        search_query = st.text_input("Search query", value="machine learning on ICP")
        max_budget = st.slider(
            "Max per request budget (ckUSDC units)",
            0, 100_000, 0,
            help="Set below 50,000 to trigger the budget guard."
        )
    with col2:
        st.write("**Canister price**")
        st.code("50,000 units\n0.05 ckUSDC")

    if st.button("Call search()", type="primary"):
        with st.spinner("Calling canister..."):
            client = st.session_state.client
            budget_client = client_from_hex(
                st.session_state.key_hex, canister_id, simulation=simulation,
                budget=BudgetConfig(max_per_request=max_budget) if max_budget > 0 else None
            )

            try:
                result = run(budget_client.call("search", search_query))
                st.success(f"Result: {result}")
                log(f"search('{search_query}') → {result}", "ok")

            except BudgetExceededError as e:
                st.error(f"Budget guard blocked the call: {e}")
                log(str(e), "warn")
                col_a, col_b = st.columns(2)
                with col_a:
                    st.metric("Canister charges", "50,000")
                with col_b:
                    st.metric("Your budget limit", f"{max_budget:,}", delta="exceeded", delta_color="inverse")

            except PaymentRequiredError as e:
                req = e.requirement
                log(f"402 PaymentRequired: {req.amount} {req.token}", "warn")
                st.warning("Payment Required — canister returned 402")

                col_a, col_b, col_c = st.columns(3)
                with col_a:
                    st.metric("Amount (units)", f"{req.amount:,}")
                with col_b:
                    st.metric("USD value", f"${req.amount / 1_000_000:.4f}")
                with col_c:
                    st.metric("Network", req.network)

                with st.expander("Full PaymentRequirement"):
                    st.json({
                        "scheme": req.scheme,
                        "network": req.network,
                        "token": req.token,
                        "amount": req.amount,
                        "recipient": req.recipient,
                        "nonce": req.nonce.hex(),
                        "expiry": req.expiry,
                    })

                st.info("Tip: use Session Flow for repeated calls — 5000x cheaper")


# ── Tab 2: Voucher Signing ────────────────────────────────────────────────────

with tab2:
    st.subheader("Ed25519 + CBOR Voucher Signing")
    st.write("Each session call is authorized by a signed **cumulative voucher** — no on-chain transaction per call.")

    col1, col2, col3 = st.columns(3)
    with col1:
        vsession = st.text_input("Session ID", value="sess-demo-001")
    with col2:
        vcumulative = st.number_input("Cumulative amount", value=3000, step=1000)
    with col3:
        vsequence = st.number_input("Sequence number", value=3, step=1)

    if st.button("Sign Voucher", type="primary"):
        private_key = st.session_state.private_key
        payload = encode_voucher_payload(vsession, int(vcumulative), int(vsequence))
        sig = sign_voucher(private_key, vsession, int(vcumulative), int(vsequence))
        voucher = Voucher(vsession, int(vcumulative), int(vsequence), sig)

        valid = verify_voucher(private_key.public_key(), voucher)
        tampered = Voucher(vsession, int(vcumulative) + 1, int(vsequence), sig)
        tampered_rejected = not verify_voucher(private_key.public_key(), tampered)

        log(f"Signed voucher seq={vsequence} cumulative={vcumulative}", "ok")

        col_a, col_b = st.columns(2)
        with col_a:
            st.write("**CBOR Payload**")
            st.code(payload.hex(), language=None)
            st.caption(f"{len(payload)} bytes — 0x83=array(3) | text | uint | uint")

            st.write("**Ed25519 Signature**")
            st.code(sig.hex(), language=None)
            st.caption("64 bytes")

        with col_b:
            st.write("**Verification**")
            if valid:
                st.success("Valid signature ✓")
            else:
                st.error("Invalid signature")
            if tampered_rejected:
                st.success("Tampered voucher rejected ✓")
            else:
                st.error("Should have been rejected")

            st.write("**Voucher struct**")
            st.json({
                "session_id": voucher.session_id,
                "cumulative_amount": voucher.cumulative_amount,
                "sequence": voucher.sequence,
                "signature": sig.hex()[:32] + "...",
            })


# ── Tab 3: Session Flow ───────────────────────────────────────────────────────

with tab3:
    st.subheader("Session Flow — Deposit Once, Call Many Times")
    client = st.session_state.client

    if not st.session_state.session_handle:
        st.write("#### Step 1 — Open session")
        col1, col2 = st.columns(2)
        with col1:
            deposit_amount = st.number_input(
                "Max deposit (ckUSDC units)", value=500_000, step=100_000,
                help="Unused funds are refunded on close"
            )
        with col2:
            st.write("**Canister offer**")
            st.code("suggested: 1,000,000\nmin:         100,000\ncost/call:     1,000")

        if st.button("Open Session", type="primary"):
            with st.spinner("Opening session..."):
                intent = run(client.request_session())
                handle = run(client.open_session(intent, max_deposit=int(deposit_amount)))
                st.session_state.session_handle = handle
                st.session_state.vouchers = []
                st.session_state.receipt = None
                log(f"Session opened: {handle.id} — deposited {handle.deposited:,}", "ok")
                st.rerun()

    else:
        handle = st.session_state.session_handle

        col1, col2, col3, col4 = st.columns(4)
        with col1:
            st.metric("Session", handle.id[-12:])
        with col2:
            st.metric("Deposited", f"{handle.deposited:,}")
        with col3:
            st.metric("Consumed", f"{handle.consumed:,}")
        with col4:
            st.metric("Remaining", f"{handle.remaining:,}",
                      delta=f"-{handle.consumed:,}" if handle.consumed else None,
                      delta_color="inverse")

        st.progress(handle.consumed / handle.deposited if handle.deposited else 0,
                    text=f"{handle.consumed / handle.deposited * 100:.1f}% of deposit used")

        st.divider()
        st.write("#### Step 2 — Make paid queries")

        col1, col2 = st.columns([3, 1])
        with col1:
            question = st.text_input("Question", value="What makes ICP unique for AI agents?")
        with col2:
            quick = st.selectbox("Quick pick", [
                "Custom",
                "What is ICP?",
                "Explain threshold ECDSA",
                "How do ICRC-2 sessions work?",
                "Why are sessions 5000x cheaper?",
                "What is ckUSDC?",
            ])
            if quick != "Custom":
                question = quick

        if st.button("Send Query (auto-signs voucher)", type="primary"):
            with st.spinner("Signing voucher and calling canister..."):
                t0 = time.perf_counter()
                answer = run(handle.call("sessionQuery", question))
                elapsed = (time.perf_counter() - t0) * 1000
                st.session_state.vouchers.append({
                    "seq": handle._sequence,
                    "question": question,
                    "answer": answer,
                    "cumulative": handle.consumed,
                    "elapsed_ms": elapsed,
                })
                log(f"[voucher #{handle._sequence}] {question[:50]}", "ok")

        if st.session_state.vouchers:
            st.write("**Voucher stream**")
            for v in reversed(st.session_state.vouchers):
                with st.container(border=True):
                    c1, c2, c3 = st.columns([1, 3, 2])
                    with c1:
                        st.write(f"**#{v['seq']}**")
                        st.caption(f"+1,000 units")
                    with c2:
                        st.write(f"Q: {v['question']}")
                        st.caption(f"A: {v['answer']}")
                    with c3:
                        st.write(f"cumulative: {v['cumulative']:,}")
                        st.caption(f"{v['elapsed_ms']:.1f} ms")

        st.divider()
        st.write("#### Step 3 — Close & get refund")

        if st.button("Close Session", type="secondary"):
            with st.spinner("Settling on-chain..."):
                receipt = run(handle.close())
                st.session_state.receipt = receipt
                st.session_state.session_handle = None
                log(f"Session closed — consumed {receipt.amount:,}, refunded {receipt.refunded:,}", "ok")
                st.rerun()

    if st.session_state.receipt:
        r = st.session_state.receipt
        st.divider()
        st.write("#### Payment Receipt")
        col1, col2, col3 = st.columns(3)
        with col1:
            st.metric("Receipt ID", r.id)
        with col2:
            st.metric("Consumed", f"{r.amount:,}", help=f"${r.amount / 1_000_000:.6f} USD")
        with col3:
            st.metric("Refunded", f"{r.refunded:,}", help=f"${r.refunded / 1_000_000:.6f} USD")
        st.success(f"{len(st.session_state.vouchers)} calls settled in just 2 on-chain transactions")

        if st.button("Start New Session"):
            st.session_state.receipt = None
            st.session_state.vouchers = []
            st.rerun()


# ── Tab 4: Activity Log ───────────────────────────────────────────────────────

with tab4:
    st.subheader("Activity Log")

    if not st.session_state.log:
        st.caption("No activity yet.")
    else:
        for kind, msg in reversed(st.session_state.log):
            if kind == "ok":
                st.success(msg)
            elif kind == "warn":
                st.warning(msg)
            elif kind == "err":
                st.error(msg)
            else:
                st.info(msg)

    if st.button("Clear log"):
        st.session_state.log = []
        st.rerun()
