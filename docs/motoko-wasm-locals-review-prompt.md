# Review prompt — IC "too many locals" (IC0505) audit for a Motoko canister

Copy everything below the line into a fresh agent/reviewer working in the target Motoko/IC
repository. It encodes a best practice ic402 learned the hard way: a perfectly-compiling
canister can be **un-installable on the IC (mainnet included)** because a single Wasm function
exceeds the replica's **2000-locals-per-function** validation limit — most often from
fully-unrolled crypto (`mo:sha2` SHA-256, `mo:sha3` Keccak) that `moc` doesn't coalesce.

---

You are auditing a Motoko project that compiles to one or more IC canisters. Your job is to
determine whether it can hit the IC's **"too many locals"** install-time validation error
(`IC0505`: *"a function … with N locals that exceeds the maximum allowed number of locals
2000"*) and to ensure the project follows the best practices that prevent it. This is a
**deploy-blocking** class of bug: `moc`/`mops` build succeeds, unit tests pass, and even some
older local replicas install it — but a current replica (and mainnet) **reject the install**.

## Background you must internalize
- A Wasm function declares **locals** (slots for intermediate values). The IC validates every
  module at install and **rejects any function with > 2000 locals** (a hardcoded, deterministic
  replica limit, enforced on mainnet). It is a *validation* limit, so the module **builds fine**
  and fails only at **install** (`IC0505`).
- The usual culprit is **fully-unrolled** code, especially crypto. `mo:sha2`'s SHA-256
  compressor writes all 64 message-schedule words + 64 rounds as straight-line `let` bindings;
  `moc` assigns a local per binding → ~2081 locals in one function. `mo:sha3` (Keccak) and other
  unrolled hashes are similar risks. Sibling functions often sit just under the cap (e.g. ~1700–1850),
  so a minimal shave is not safe.
- The fix is normally **not** a rewrite: a `wasm-opt -O --all-features` build step coalesces the
  locals (non-overlapping live ranges share slots) and typically drops a 2081-local function to
  **< 150**. Requires a **recent binaryen (≥ v130)** — older/bundled `wasm-opt` (e.g. the one in
  some `ic-wasm` builds) fails on `moc`'s 64-bit table with *"Tables may not be 64-bit."*

## Tasks
1. **Reproduce / measure.** Build the canister Wasm (`mops`/`moc` or the project's build) and
   either (a) attempt `dfx deploy` / `icp deploy` against a **current** replica/pocket-ic and look
   for `IC0505`, or (b) measure the **max per-function locals** in the built `.wasm` (parse the
   Code section: for each function body, sum its local-decl counts; report the max + which
   function). Flag any function **> ~1900** locals (cap is 2000; leave headroom).
2. **Find the sources.** Grep for unrolled-crypto deps and large straight-line functions:
   `mo:sha2`, `mo:sha3`, hand-written hash/cipher round expansions, big `let`-chains. List the
   import/call sites. Confirm whether Keccak/SHA-512/etc. are *also* near/over the cap.
3. **Check the mitigations are present** (this is the "best practice embedded" check):
   - **Build optimization:** does the build run `wasm-opt -O` / `ic-wasm optimize` (with a binaryen
     new enough for the module's features)? If the build pipeline emits an un-optimized Wasm, that's
     a finding.
   - **CI install gate:** does CI actually **install** the canister on a replica (not just build +
     unit-test)? A build-only CI lets `IC0505` ship undetected. Missing gate = a finding.
   - **Code shape:** are large functions **looped** (array-indexed state) rather than unrolled, and
     are oversized functions **decomposed** (the limit is *per function*)?
   - **Dependency hygiene:** are crypto/encoding deps vetted to install on a current IC?
4. **Report + recommend.** For each gap, give the concrete fix, preferring cheapest-first:
   (a) add a `wasm-opt -O --all-features` build step + pin binaryen ≥ v130; (b) decompose or
   loop the offending function; (c) only if optimization can't help, vendor a loop-based
   implementation (NIST/RFC test-vector it). Always recommend adding the **CI install gate** so
   the class can't regress.

## Acceptance criteria (what "embedded" looks like)
- The build emits an **optimized** Wasm whose **max per-function locals < ~1500** (comfortable
  headroom), verified by measurement.
- CI **installs** the canister on a current replica and **fails on `IC0505`** (or any install
  rejection), not merely builds it.
- Crypto/large functions are looped/decomposed or run through `wasm-opt`; the binaryen version is
  pinned and recent enough for the module's Wasm features.
- A short note in the repo (CHANGELOG/SECURITY/build docs) records the limit and the optimize step,
  so the next contributor doesn't reintroduce an unrolled, un-installable function.

Be skeptical and evidence-based: a green `mops test` and a successful `moc` build prove **nothing**
about installability. Only an install on a current replica (or a measured locals count) does.
