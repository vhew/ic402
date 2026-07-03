/// Motoko unit tests for EvmEscrowManager — virtual escrow accounting for EVM session
/// deposits on the canister's shared EVM address. Encodes review invariant #7 (escrow
/// solvency): the over-allocation guard and per-chain/token accounting. The manager has
/// no on-chain visibility, so these accounting properties are what stops concurrent EVM
/// sessions from over-committing the shared balance — previously untested.
import EvmEscrow "../src/ic402/EvmEscrow";
import { test; suite } "mo:test";

suite("EvmEscrowManager", func() {

  test("allocate then getAllocation returns the amount", func() {
    let m = EvmEscrow.EvmEscrowManager();
    switch (m.allocate("s1", 8453, "0xusdc", 1000)) { case (#ok) {}; case (#err(_)) { assert false } };
    switch (m.getAllocation("s1")) { case (?a) { assert a == 1000 }; case null { assert false } };
  });

  test("double-allocate the same session is rejected (no silent over-allocation)", func() {
    let m = EvmEscrow.EvmEscrowManager();
    switch (m.allocate("s1", 8453, "0xusdc", 1000)) { case (#ok) {}; case (#err(_)) { assert false } };
    switch (m.allocate("s1", 8453, "0xusdc", 1000)) { case (#err(_)) {}; case (#ok) { assert false } };
    // The amount is unchanged by the rejected second allocation.
    switch (m.getAllocation("s1")) { case (?a) { assert a == 1000 }; case null { assert false } };
  });

  test("totalAllocated sums per chain+token and isolates other chains/tokens", func() {
    let m = EvmEscrow.EvmEscrowManager();
    ignore m.allocate("s1", 8453, "0xusdc", 1000);
    ignore m.allocate("s2", 8453, "0xusdc", 500);
    ignore m.allocate("s3", 8453, "0xother", 9999); // different token
    ignore m.allocate("s4", 1, "0xusdc", 7777);     // different chain
    assert (m.totalAllocated(8453, "0xusdc") == 1500);
    assert (m.totalAllocated(8453, "0xother") == 9999);
    assert (m.totalAllocated(1, "0xusdc") == 7777);
    assert (m.totalAllocated(10, "0xusdc") == 0); // unused chain
  });

  test("deallocate frees the slot and returns the allocation", func() {
    let m = EvmEscrow.EvmEscrowManager();
    ignore m.allocate("s1", 8453, "0xusdc", 1000);
    switch (m.deallocate("s1")) { case (?a) { assert a.amount == 1000 }; case null { assert false } };
    switch (m.getAllocation("s1")) { case null {}; case (?_) { assert false } };
    assert (m.totalAllocated(8453, "0xusdc") == 0);
    // After dealloc the session id can be re-allocated (no stale slot left behind).
    switch (m.allocate("s1", 8453, "0xusdc", 200)) { case (#ok) {}; case (#err(_)) { assert false } };
    assert (m.totalAllocated(8453, "0xusdc") == 200);
  });

  // SEC-0: the pool cap turns totalAllocated into a LIVE over-allocation guard (per chain+token).
  test("poolCap refuses allocations past the funded pool size", func() {
    let m = EvmEscrow.EvmEscrowManager();
    m.setPoolCap(?1000);
    switch (m.allocate("s1", 8453, "0xusdc", 600)) { case (#ok) {}; case (#err(_)) { assert false } };
    // Would exceed the cap (600 + 500 > 1000) → refused; the shared pool can't be over-reserved.
    switch (m.allocate("s2", 8453, "0xusdc", 500)) { case (#err(_)) {}; case (#ok) { assert false } };
    // Exactly filling the cap (600 + 400 == 1000) is allowed.
    switch (m.allocate("s2", 8453, "0xusdc", 400)) { case (#ok) {}; case (#err(_)) { assert false } };
    assert (m.totalAllocated(8453, "0xusdc") == 1000);
    // The cap applies per chain+token: a different token has its own headroom up to the cap.
    switch (m.allocate("s3", 8453, "0xother", 800)) { case (#ok) {}; case (#err(_)) { assert false } };
    switch (m.allocate("s4", 8453, "0xother", 300)) { case (#err(_)) {}; case (#ok) { assert false } };
    // Clearing the cap (null) restores unbounded allocation.
    m.setPoolCap(null);
    switch (m.allocate("s5", 8453, "0xusdc", 999999)) { case (#ok) {}; case (#err(_)) { assert false } };
  });

  test("getPoolCap reads back setPoolCap (default null = unbounded)", func() {
    let m = EvmEscrow.EvmEscrowManager();
    assert (m.getPoolCap() == null);
    m.setPoolCap(?9_000);
    assert (m.getPoolCap() == ?9_000);
    m.setPoolCap(null);
    assert (m.getPoolCap() == null);
  });
});
