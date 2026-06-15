/// Motoko unit tests for Policy engine.
import Policy "../src/ic402/Policy";
import Principal "mo:base/Principal";
import Time "mo:base/Time";
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

  // H-4 (v2) reserve/release regression tests.
  test("reserve then releaseDaily nets to zero (same day)", func() {
    let engine = Policy.Engine();
    let day = engine.currentDay();
    engine.recordSpend(caller1, 40_000);
    assert(engine.getDailySpendAmount(caller1) == 40_000);
    engine.releaseDaily(caller1, day, 40_000);
    assert(engine.getDailySpendAmount(caller1) == 0);
  });

  test("releaseDaily clamps to 0 and never underflows", func() {
    let engine = Policy.Engine();
    let day = engine.currentDay();
    engine.recordSpend(caller1, 10_000);
    // Release MORE than was recorded — must clamp to 0, not trap/underflow.
    engine.releaseDaily(caller1, day, 999_999);
    assert(engine.getDailySpendAmount(caller1) == 0);
  });

  test("releaseDaily on the wrong day leaves today's bucket intact (H-4 day-bucket fix)", func() {
    let engine = Policy.Engine();
    let day = engine.currentDay();
    engine.recordSpend(caller1, 50_000);
    // A release keyed to a DIFFERENT day (e.g. a settlement that crossed midnight
    // releasing against the current day) must NOT touch the reservation's bucket.
    engine.releaseDaily(caller1, day + 1, 50_000);
    assert(engine.getDailySpendAmount(caller1) == 50_000);
    // Releasing against the correct day clears it.
    engine.releaseDaily(caller1, day, 50_000);
    assert(engine.getDailySpendAmount(caller1) == 0);
  });

  // S-21: a caller blocked AFTER a session was opened must not be able to keep
  // draining it via vouchers — checkVoucher must enforce the allow/block list.
  test("checkVoucher rejects a blocked caller", func() {
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
    switch (engine.checkVoucher(caller1, 1_000)) {
      case (#ok) { assert(false) };
      case (#denied(_)) {};
    };
  });

  // C-9: the deposit is reserved against the daily bucket ONCE, at open. checkVoucher
  // must not re-charge each voucher delta against the daily limit, or a funded session
  // whose deposit nears maxPerDay becomes unusable.
  test("checkVoucher does not double-count the deposit against the daily limit", func() {
    let engine = Policy.Engine();
    engine.setGlobalPolicy({
      maxPerTransaction = null;
      maxPerDay = ?60_000;
      rateLimitPerMinute = null;
      maxSessionDeposit = null;
      maxConcurrentSessions = null;
      maxSessionDuration = null;
      sessionIdleTimeout = null;
      allowedCallers = null;
      blockedCallers = null;
    });
    // Simulate session-open reserving the full 60_000 deposit against today's bucket.
    engine.recordSpend(caller1, 60_000);
    // A subsequent voucher delta must still be permitted — the deposit already covers it.
    switch (engine.checkVoucher(caller1, 500)) {
      case (#ok) {};
      case (#denied(_)) { assert(false) };
    };
  });

  // S-11: gcRateLimit() reclaims principals whose rate-limit window has fully aged out,
  // bounding rateLimitLog so unauthenticated settle attempts cannot grow it without limit.
  test("gcRateLimit reclaims stale rate-limit entries but keeps fresh ones", func() {
    let engine = Policy.Engine();
    let key1 = Principal.toText(caller1);
    let key2 = Principal.toText(caller2);
    // Inject one stale (far-past timestamp, guaranteed < now-60s for any clock) and one
    // fresh (now) entry via stable restore. Using an absolute past value keeps the test
    // independent of whatever Time.now() the test runtime reports.
    let base = engine.toStable();
    engine.loadStable({
      base with rateLimitEntries = [(key1, [-100_000_000_000]), (key2, [Time.now()])]
    });
    assert(engine.rateLimitEntryCount() == 2);
    engine.gcRateLimit();
    // The stale principal is reclaimed; the fresh one survives.
    assert(engine.rateLimitEntryCount() == 1);
  });

  // getGlobalPolicy reads back exactly what setGlobalPolicy stored — this is what
  // the canister's getPolicyConfig query exposes for live policy display.
  test("getGlobalPolicy round-trips the configured policy", func() {
    let engine = Policy.Engine();
    let p = {
      maxPerTransaction = ?50_000;
      maxPerDay = ?500_000;
      rateLimitPerMinute = ?120;
      maxSessionDeposit = ?100_000;
      maxConcurrentSessions = ?1;
      maxSessionDuration = ?(24 * 60 * 60 * 1_000_000_000);
      sessionIdleTimeout = ?(60 * 60 * 1_000_000_000);
      allowedCallers = null;
      blockedCallers = null;
    };
    engine.setGlobalPolicy(p);
    let got = engine.getGlobalPolicy();
    assert(got.maxPerTransaction == ?50_000);
    assert(got.maxPerDay == ?500_000);
    assert(got.rateLimitPerMinute == ?120);
    assert(got.maxSessionDeposit == ?100_000);
    assert(got.maxConcurrentSessions == ?1);
    assert(got.sessionIdleTimeout == ?(60 * 60 * 1_000_000_000));
    assert(got.maxSessionDuration == ?(24 * 60 * 60 * 1_000_000_000));
  });
});
