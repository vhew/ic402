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
});
