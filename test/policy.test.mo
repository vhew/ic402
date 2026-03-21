/// Motoko unit tests for Policy engine.
import Policy "../src/agentflow/Policy";
import Principal "mo:base/Principal";
import { test; suite } "mo:test";

suite("Policy.Engine", func() {

  let caller1 = Principal.fromText("aaaaa-aa");
  let caller2 = Principal.fromText("2vxsx-fae");

  test("allows charge within limits", func() {
    let engine = Policy.Engine();
    engine.setGlobalPolicy({
      maxPerTransaction = ?100_000;
      maxPerDay = ?1_000_000;
      rateLimitPerMinute = ?60;
      maxSessionDeposit = null;
      maxConcurrentSessions = ?1;
      maxSessionDuration = null;
      sessionIdleTimeout = null;
      allowedCallers = null;
      blockedCallers = null;
    });

    switch (engine.checkCharge(caller1, 50_000)) {
      case (#ok) {};
      case (#denied(_)) { assert(false) };
    };
  });

  test("rejects charge exceeding maxPerTransaction", func() {
    let engine = Policy.Engine();
    engine.setGlobalPolicy({
      maxPerTransaction = ?100_000;
      maxPerDay = null;
      rateLimitPerMinute = null;
      maxSessionDeposit = null;
      maxConcurrentSessions = null;
      maxSessionDuration = null;
      sessionIdleTimeout = null;
      allowedCallers = null;
      blockedCallers = null;
    });

    switch (engine.checkCharge(caller1, 200_000)) {
      case (#ok) { assert(false) };
      case (#denied(_)) {};
    };
  });

  test("rejects blocked caller", func() {
    let engine = Policy.Engine();
    engine.setGlobalPolicy({
      maxPerTransaction = null;
      maxPerDay = null;
      rateLimitPerMinute = null;
      maxSessionDeposit = null;
      maxConcurrentSessions = null;
      maxSessionDuration = null;
      sessionIdleTimeout = null;
      allowedCallers = null;
      blockedCallers = ?[caller1];
    });

    switch (engine.checkCharge(caller1, 1_000)) {
      case (#ok) { assert(false) };
      case (#denied(r)) {
        assert(r == "Caller is blocked");
      };
    };

    // caller2 is not blocked
    switch (engine.checkCharge(caller2, 1_000)) {
      case (#ok) {};
      case (#denied(_)) { assert(false) };
    };
  });

  test("enforces allowlist", func() {
    let engine = Policy.Engine();
    engine.setGlobalPolicy({
      maxPerTransaction = null;
      maxPerDay = null;
      rateLimitPerMinute = null;
      maxSessionDeposit = null;
      maxConcurrentSessions = null;
      maxSessionDuration = null;
      sessionIdleTimeout = null;
      allowedCallers = ?[caller1];
      blockedCallers = null;
    });

    switch (engine.checkCharge(caller1, 1_000)) {
      case (#ok) {};
      case (#denied(_)) { assert(false) };
    };

    switch (engine.checkCharge(caller2, 1_000)) {
      case (#ok) { assert(false) };
      case (#denied(r)) {
        assert(r == "Caller not in allowlist");
      };
    };
  });

  test("per-caller policy overrides global", func() {
    let engine = Policy.Engine();
    engine.setGlobalPolicy({
      maxPerTransaction = ?100_000;
      maxPerDay = null;
      rateLimitPerMinute = null;
      maxSessionDeposit = null;
      maxConcurrentSessions = null;
      maxSessionDuration = null;
      sessionIdleTimeout = null;
      allowedCallers = null;
      blockedCallers = null;
    });

    // Set caller-specific policy with higher limit
    engine.setCallerPolicy(caller1, {
      maxPerTransaction = ?500_000;
      maxPerDay = null;
      rateLimitPerMinute = null;
      maxSessionDeposit = null;
      maxConcurrentSessions = null;
      maxSessionDuration = null;
      sessionIdleTimeout = null;
      allowedCallers = null;
      blockedCallers = null;
    });

    // caller1 can do 200k (above global limit)
    switch (engine.checkCharge(caller1, 200_000)) {
      case (#ok) {};
      case (#denied(_)) { assert(false) };
    };

    // caller2 uses global limit, 200k is rejected
    switch (engine.checkCharge(caller2, 200_000)) {
      case (#ok) { assert(false) };
      case (#denied(_)) {};
    };
  });

  test("session: checks concurrent limit", func() {
    let engine = Policy.Engine();
    engine.setGlobalPolicy({
      maxPerTransaction = null;
      maxPerDay = null;
      rateLimitPerMinute = null;
      maxSessionDeposit = null;
      maxConcurrentSessions = ?2;
      maxSessionDuration = null;
      sessionIdleTimeout = null;
      allowedCallers = null;
      blockedCallers = null;
    });

    // 0 active sessions → ok
    switch (engine.checkSessionOpen(caller1, 100_000, 0)) {
      case (#ok) {};
      case (#denied(_)) { assert(false) };
    };

    // 1 active session → ok
    switch (engine.checkSessionOpen(caller1, 100_000, 1)) {
      case (#ok) {};
      case (#denied(_)) { assert(false) };
    };

    // 2 active sessions → rejected
    switch (engine.checkSessionOpen(caller1, 100_000, 2)) {
      case (#ok) { assert(false) };
      case (#denied(_)) {};
    };
  });

  test("session: checks deposit limit", func() {
    let engine = Policy.Engine();
    engine.setGlobalPolicy({
      maxPerTransaction = null;
      maxPerDay = null;
      rateLimitPerMinute = null;
      maxSessionDeposit = ?500_000;
      maxConcurrentSessions = null;
      maxSessionDuration = null;
      sessionIdleTimeout = null;
      allowedCallers = null;
      blockedCallers = null;
    });

    switch (engine.checkSessionOpen(caller1, 400_000, 0)) {
      case (#ok) {};
      case (#denied(_)) { assert(false) };
    };

    switch (engine.checkSessionOpen(caller1, 600_000, 0)) {
      case (#ok) { assert(false) };
      case (#denied(_)) {};
    };
  });

  test("daily spend tracking", func() {
    let engine = Policy.Engine();
    engine.setGlobalPolicy({
      maxPerTransaction = null;
      maxPerDay = ?100_000;
      rateLimitPerMinute = null;
      maxSessionDeposit = null;
      maxConcurrentSessions = null;
      maxSessionDuration = null;
      sessionIdleTimeout = null;
      allowedCallers = null;
      blockedCallers = null;
    });

    // Record some spend
    engine.recordSpend(caller1, 80_000);
    assert(engine.getDailySpendAmount(caller1) == 80_000);

    // Should reject charge that would exceed daily limit
    switch (engine.checkCharge(caller1, 30_000)) {
      case (#ok) { assert(false) };
      case (#denied(_)) {};
    };

    // But a smaller charge is ok
    switch (engine.checkCharge(caller1, 10_000)) {
      case (#ok) {};
      case (#denied(_)) { assert(false) };
    };
  });

  test("toStable and loadStable roundtrip", func() {
    let engine = Policy.Engine();
    engine.setGlobalPolicy({
      maxPerTransaction = ?100_000;
      maxPerDay = ?1_000_000;
      rateLimitPerMinute = ?60;
      maxSessionDeposit = null;
      maxConcurrentSessions = ?1;
      maxSessionDuration = null;
      sessionIdleTimeout = null;
      allowedCallers = null;
      blockedCallers = null;
    });
    engine.recordSpend(caller1, 50_000);

    let snapshot = engine.toStable();

    let engine2 = Policy.Engine();
    engine2.loadStable(snapshot);

    let policy = engine2.getGlobalPolicy();
    assert(policy.maxPerTransaction == ?100_000);
    assert(engine2.getDailySpendAmount(caller1) == 50_000);
  });

  test("voucher: checks rate limit and daily spend", func() {
    let engine = Policy.Engine();
    engine.setGlobalPolicy({
      maxPerTransaction = null;
      maxPerDay = ?100_000;
      rateLimitPerMinute = ?2;
      maxSessionDeposit = null;
      maxConcurrentSessions = null;
      maxSessionDuration = null;
      sessionIdleTimeout = null;
      allowedCallers = null;
      blockedCallers = null;
    });

    // First two vouchers within rate limit
    switch (engine.checkVoucher(caller1, 1_000)) {
      case (#ok) {};
      case (#denied(_)) { assert(false) };
    };
    switch (engine.checkVoucher(caller1, 1_000)) {
      case (#ok) {};
      case (#denied(_)) { assert(false) };
    };

    // Third voucher exceeds rate limit (2/min)
    switch (engine.checkVoucher(caller1, 1_000)) {
      case (#ok) { assert(false) };
      case (#denied(_)) {};
    };
  });
});
