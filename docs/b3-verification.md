# B3 — verifying EVM settlement on-chain end-to-end

**Goal (B3):** observe a *green, mined* (`status==1`) on-chain transfer through ic402's own
tECDSA sender for (1) a charge settle, (2) an EVM streaming-session close+refund, and
(3) a marketplace job settle. The signing/contract side is already proven; what B3 confirms
is the canister actually **broadcasting + confirming** funded transfers (the B2-confirmed path).

Everything below runs against a **local replica** whose canister makes real HTTPS outcalls to
**Base Sepolia** — so the canister is local, but the USDC transfers are real testnet transfers
and need real testnet funds.

## Prerequisites
- A working replica + installed canister: `pnpm setup:local` (now succeeds since B0 is fixed —
  it installs the wasm-opt'd module, derives the tECDSA EVM address, and funds the test payer).
- [foundry](https://getfoundry.sh) `cast` (for the evidence helper).
- The two on-chain addresses, **funded on Base Sepolia (chainId 84532)**:
  | Address | Role | Fund with |
  |---|---|---|
  | clean-EOA demo **payer** — `0x26e42bf529b41bda6e5b587e57680949ac739e86` (default; or your `IC402_DEMO_EVM_KEY`) | signs the EIP-3009 *inbound* payments | **USDC** ≥ the amounts you'll pay — [faucet.circle.com](https://faucet.circle.com) |
  | **canister** EVM address — `0x923f4e32aceed37012c11bb2f19d62c30b0be3ab` (`dfx_test_key`; confirm with `icp canister call example getEvmAddress '()' -e local`) | pays gas for every broadcast; holds USDC it pays *out* for marketplace/session refunds | **Base Sepolia ETH** (gas) + **USDC** (for the outbound settle/refund legs) |

  ⚠️ The payer must be a **clean EOA with no on-chain code** (Circle USDC routes code-bearing
  addresses to EIP-1271 and rejects plain ECDSA EIP-3009). The default demo key is clean; if you
  override with `IC402_DEMO_EVM_KEY`, use a fresh key. The demo's `eth_getCode` preflight enforces this.

## Step A — charge settle (demo Step 3)
```bash
pnpm demo        # → Step 3 (SELL Content) → choose Base Sepolia
```
The demo signs an EIP-3009 authorization as the clean EOA; the canister verifies EIP-712 locally,
broadcasts `transferWithAuthorization` via tECDSA, and `confirmTransaction` polls for `status==1`
before issuing the receipt. Copy the tx hash from the receipt and:
```bash
./scripts/verify-evm-settle.sh <txhash>
```

## Step B — EVM session close + refund (demo Step 7)
```bash
pnpm demo        # → Step 7 (Streaming Micropayments) → choose an EVM chain
```
`open_session` deposits via EIP-3009; vouchers stream; `close_session` settles consumed →
recipient and refunds remainder → payer via `sendErc20TransferConfirmed` (both legs confirmed
on-chain — the B2 fix). The receipt carries a `settle|refund` two-hash; verify both:
```bash
./scripts/verify-evm-settle.sh <settleTx> <refundTx>
```
If it parks in `#closing` with a fee/RPC error, that's a transient RPC issue (retry) — not a bug.

## Step C — marketplace job settle (the EVM-rail consumer)
The marketplace EVM rail is recorded **only** via the HTTP `/service/{id}` route (the buyer is the
0x EIP-3009 sender there; the Candid `submitServiceRequest`/MCP path uses the caller principal and
never records a rail). Drive it with:
```bash
tsx scripts/drive-evm-marketplace.ts        # operator identity = the local test identity
```
It registers + enables an AutoSettle service, registers the operator's EVM payout, pays the service
request over `/service/{id}` with a clean-EOA EIP-3009 authorization (records the rail), then claims
+ submits the result → AutoSettle → `settleJob` → `settleToOperator` takes the **EVM branch** and
transfers the operator's payout on-chain (confirmed). It prints the settle tx hash; verify it:
```bash
./scripts/verify-evm-settle.sh <settleTx>
```
Note: this needs the **canister** EVM address funded with USDC (it pays the operator *out*) on top
of the payer's USDC for the inbound leg.

## Record the evidence
Capture the mined tx hashes (Steps A/B/C) in the PR / CHANGELOG as the B3 proof, e.g.:
> B3 verified on Base Sepolia: charge settle `0x…`, session settle `0x…` + refund `0x…`,
> marketplace settle `0x…` — all `status==1`.

Steps A + B alone satisfy the core B3 definition (a green settle + a green session close/refund);
Step C additionally exercises the marketplace `settleJob` consumer, which reuses the same
`sendErc20TransferConfirmed` mechanism as Step B.
