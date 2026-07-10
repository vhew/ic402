# Official Candid interfaces (vendored, pinned)

These are byte-for-byte copies of the OFFICIAL Candid interfaces of the external
canisters ic402 calls. They are the ground truth for the candid-mirror drift gate
(`scripts/check-candid-mirrors.sh`), which proves — hermetically, offline — that the
repo's Motoko mirror types (`Types.LedgerActor` in `src/ic402/Types.mo`,
`EvmRpc.EvmRpcCanister` in `src/ic402/EvmRpc.mo`) stay decode-safe against them.
Do NOT hand-edit; refresh deliberately (see below) so every change is a reviewed diff.

## Files

| File | Source | Pinned at | sha256 |
| --- | --- | --- | --- |
| `ICRC-1.did` | [dfinity/ICRC-1](https://github.com/dfinity/ICRC-1) `standards/ICRC-1/ICRC-1.did` (normative standard) | `main` @ `f8c39bec71b1ac7f6cdb1a6c9844726efc58be38` (fetched 2026-07-10) | `bcefc2af41745128fb295a895cc63aa0f1931918472afca4007d5adce65734f4` |
| `ICRC-2.did` | [dfinity/ICRC-1](https://github.com/dfinity/ICRC-1) `standards/ICRC-2/ICRC-2.did` (normative standard) | `main` @ `f8c39bec71b1ac7f6cdb1a6c9844726efc58be38` (fetched 2026-07-10) | `f436b04176b81f7c86948a200a4474b5d8be45e0bed05005434a6085db4fa6a5` |
| `evm_rpc.did` | [dfinity/evm-rpc-canister](https://github.com/dfinity/evm-rpc-canister) `candid/evm_rpc.did` | release tag `v2.8.0` (fetched 2026-07-10) | `11735568b4b4fd80fb0075b6f0ff06c592da1a182d08b786f76de2d1118feedd` |

## Why evm_rpc.did is pinned to v2.8.0 (not repo `main`)

The v2.8.0 interface is **sha256-byte-identical to the DEPLOYED mainnet EVM-RPC
canister** `7hfb6-caaaa-aaaar-qadga-cai` — its `candid:service` metadata was fetched
live on 2026-07-10 (agent-js `CanisterStatus`, dfx unavailable) and hashed to the same
`11735568…` digest. Repo `main` (`a27d58daef78f7fd42082ac8f75f95811da2cdea` at fetch
time) differs only by a not-yet-deployed `batch`/`batchCyclesCost` API plus a comment
line. ic402 talks to the deployed canister, so the deployed interface is the contract
the mirrors must decode against; tracking `main` would gate against methods/types that
do not exist on the wire yet. Raw fetch artifacts (deployed .did, main .did, diff) were
captured in the generation workspace; the decisive fact — hash equality with the live
canister — is recorded here.

The ICRC dids come from the normative standard (the interface every compliant ledger,
including the ICP ledger and the ICRC-1 ledger suite, must serve). The generation run
also cross-checked the mirrors against the `dfinity/ic` ledger-suite dids
(`rs/ledger_suite/icp/ledger.did`, `rs/ledger_suite/icrc1/ledger/ledger.did`) with
zero decode discrepancies.

## Refresh instructions

Refreshing is a deliberate, reviewed act — a drifted upstream interface may require
mirror-type changes in `src/ic402/` first (that is exactly what the gate exists to
catch). To refresh:

```bash
cd test/fixtures/official

# ICRC (normative standard; record the commit you pinned)
git ls-remote https://github.com/dfinity/ICRC-1 refs/heads/main   # note the SHA
curl -fsSL "https://raw.githubusercontent.com/dfinity/ICRC-1/<SHA>/standards/ICRC-1/ICRC-1.did" -o ICRC-1.did
curl -fsSL "https://raw.githubusercontent.com/dfinity/ICRC-1/<SHA>/standards/ICRC-2/ICRC-2.did" -o ICRC-2.did

# EVM-RPC: pin the release matching the DEPLOYED canister. Verify by fetching the live
# candid:service metadata and comparing hashes BEFORE bumping the pin:
#   dfx canister --network ic metadata 7hfb6-caaaa-aaaar-qadga-cai candid:service | shasum -a 256
curl -fsSL "https://raw.githubusercontent.com/dfinity/evm-rpc-canister/v<X.Y.Z>/candid/evm_rpc.did" -o evm_rpc.did

shasum -a 256 *.did   # update the table above with new hashes + commit/tag + date
bash ../../../scripts/check-candid-mirrors.sh              # gate must still pass
bash ../../../scripts/check-candid-mirrors.sh --self-test  # gate must still discriminate
```

If the gate fails after a refresh, the official interface drifted in a way the mirrors
cannot decode — fix `src/ic402/Types.mo` / `src/ic402/EvmRpc.mo` (and their probes in
`test/candid-probes/`) before landing the refreshed fixtures.
