/// Unit tests for the EvmSender pure fee helpers (module scope).
/// These lock in the fee-data math, including the S16 10_000 gwei ceiling that
/// bounds an absurd base fee from a single hostile/buggy RPC provider once fee
/// data no longer requires strict multi-provider agreement.
import EvmSender "../src/ic402/EvmSender";
import EvmRpc "../src/ic402/EvmRpc";
import { test; suite } "mo:test";

suite("EvmSender fee helpers", func() {

  let CEILING = 10_000_000_000_000; // 10_000 gwei

  // feeFromBase: priority = base clamped to [1e6, 1.5 gwei]; maxFee = 2*base + priority.

  test("feeFromBase: base above 1.5 gwei caps the priority fee", func() {
    let (maxFee, priority) = EvmSender.feeFromBase(2_000_000_000); // 2 gwei
    assert(priority == 1_500_000_000);
    assert(maxFee == 2 * 2_000_000_000 + 1_500_000_000);
  });

  test("feeFromBase: mid base fee makes priority == base", func() {
    let (maxFee, priority) = EvmSender.feeFromBase(1_000_000_000); // 1 gwei
    assert(priority == 1_000_000_000);
    assert(maxFee == 2 * 1_000_000_000 + 1_000_000_000);
  });

  test("feeFromBase: tiny base fee floors the priority at 1e6", func() {
    let (maxFee, priority) = EvmSender.feeFromBase(500_000); // below 1e6
    assert(priority == 1_000_000);
    assert(maxFee == 2 * 500_000 + 1_000_000);
  });

  test("feeFromBase: clamps an absurd base fee to the 10_000 gwei ceiling (S16)", func() {
    // A hostile/buggy provider returns 10^30 wei; the clamp caps base at the ceiling
    // so maxFeePerGas can't be inflated into an unpayable upfront gas reservation.
    let (maxFee, priority) = EvmSender.feeFromBase(1_000_000_000_000_000_000_000_000_000_000);
    assert(priority == 1_500_000_000);
    assert(maxFee == 2 * CEILING + 1_500_000_000);
  });

  test("feeFromBase: a base fee exactly at the ceiling is unchanged", func() {
    let (maxFee, priority) = EvmSender.feeFromBase(CEILING);
    assert(priority == 1_500_000_000);
    assert(maxFee == 2 * CEILING + 1_500_000_000);
  });

  // latestBaseFee: prefer index 1 (forecast next block), then index 0, else null.

  test("latestBaseFee: prefers the forecast next-block base (index 1)", func() {
    let h : EvmRpc.FeeHistory = { reward = []; gasUsedRatio = []; oldestBlock = 0; baseFeePerGas = [111, 222] };
    switch (EvmSender.latestBaseFee(h)) { case (?b) { assert(b == 222) }; case null { assert(false) } };
  });

  test("latestBaseFee: falls back to the current block (index 0)", func() {
    let h : EvmRpc.FeeHistory = { reward = []; gasUsedRatio = []; oldestBlock = 0; baseFeePerGas = [333] };
    switch (EvmSender.latestBaseFee(h)) { case (?b) { assert(b == 333) }; case null { assert(false) } };
  });

  test("latestBaseFee: null on an empty array", func() {
    let h : EvmRpc.FeeHistory = { reward = []; gasUsedRatio = []; oldestBlock = 0; baseFeePerGas = [] };
    switch (EvmSender.latestBaseFee(h)) { case (?_) { assert(false) }; case null {} };
  });

  // SEC-2: robustBaseFee = lower median, so one outlier provider can't pick an unpayable gas fee.
  test("robustBaseFee: null on no data", func() {
    switch (EvmSender.robustBaseFee([])) { case (?_) { assert(false) }; case null {} };
  });
  test("robustBaseFee: single provider returns its value", func() {
    switch (EvmSender.robustBaseFee([100])) { case (?b) { assert(b == 100) }; case null { assert(false) } };
  });
  test("robustBaseFee: 2 providers take the LOWER (neutralises a high outlier)", func() {
    switch (EvmSender.robustBaseFee([100, 999_999_999])) { case (?b) { assert(b == 100) }; case null { assert(false) } };
    switch (EvmSender.robustBaseFee([999_999_999, 100])) { case (?b) { assert(b == 100) }; case null { assert(false) } };
  });
  test("robustBaseFee: 3 providers take the MIDDLE (ignore one high AND one low outlier)", func() {
    switch (EvmSender.robustBaseFee([100, 200, 300])) { case (?b) { assert(b == 200) }; case null { assert(false) } };
    // a hostile huge fee + a near-zero fee are both ignored
    switch (EvmSender.robustBaseFee([200, 1_000_000_000_000_000, 1])) { case (?b) { assert(b == 200) }; case null { assert(false) } };
  });
});
