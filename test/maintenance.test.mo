/// Host-driven clean-up (2.19.0): Gateway.runMaintenance and the bounded clean-ups behind it.
///
/// A host that starts the gateway with startTimersWith({ hourlyGc = false }) relies on
/// runMaintenance alone to keep three maps from growing: daily spend, the rate-limit log (keyed on
/// attacker-chosen payer principals, SEC-1) and revoked grants. These tests plant stale and live
/// entries through loadStable, since mo:test's clock is fixed, and pin that each map is cleaned,
/// live entries stay, and the per-call cap holds.
///
/// Not testable here: whether startTimersWith arms the hourly timer. mops test has no timer API
/// (see test/expirytimer.test.mo). maintenanceTimerArmed() exposes it for replica tests instead.
import Gateway "../src/ic402/Gateway";
import Policy "../src/ic402/Policy";
import Grants "../src/ic402/Grants";
import Types "../src/ic402/Types";
import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Nat "mo:base/Nat";
import Time "mo:base/Time";
import { test; suite } "mo:test";

let owner = Principal.fromText("aaaaa-aa");
let config : Types.Config = {
  recipient = { owner; subaccount = null };
  tokens = [];
  evmChains = [];
  evmRpcCanister = null;
  ecdsaKeyName = null;
  nonceExpirySeconds = null;
};

let now = Time.now();
let SEC : Int = 1_000_000_000;
let DAY : Int = 86_400 * SEC;
let today : Int = now / DAY;

func tabulate<T>(n : Nat, f : Nat -> T) : [T] = Array.tabulate<T>(n, f);
func key(day : Int, i : Nat) : Text = debug_show (day) # ":p" # Nat.toText(i);

// Stale entries: spend from yesterday and a malformed key; rate-limit hits older than 60 s;
// grants revoked more than 7 days ago. Live entries: today's spend, a hit now, a fresh revocation.
func staleDaily(n : Nat) : [(Text, Nat)] = tabulate<(Text, Nat)>(n, func(i) = (key(today - 1, i), 5));
func staleRate(n : Nat) : [(Text, [Int])] = tabulate<(Text, [Int])>(n, func(i) = ("r" # Nat.toText(i), [now - 61 * SEC]));
func staleGrants(n : Nat) : [(Text, Int)] = tabulate<(Text, Int)>(n, func(i) = ("g" # Nat.toText(i), now - 8 * DAY));
let liveDaily : [(Text, Nat)] = [(key(today, 0), 7)];
let liveRate : [(Text, [Int])] = [("live", [now - 61 * SEC, now])];
let liveGrants : [(Text, Int)] = [("fresh", now - 6 * DAY)];

// A gateway restored with the given entries.
func gatewayWith(daily : [(Text, Nat)], rate : [(Text, [Int])], revoked : [(Text, Int)]) : Gateway.Gateway {
  let gate = Gateway.Gateway(config, owner);
  let s = gate.toStable();
  let g = switch (s.accessGrants) {
    case (?g) { g };
    case (null) { { revokedGrantIds = []; revokedGrantTimestamps = null; grantCounter = 0; hmacSeed = 0 } };
  };
  gate.loadStable({
    s with
    policy = { s.policy with dailySpendEntries = daily; rateLimitEntries = rate };
    accessGrants = ?{ g with revokedGrantTimestamps = ?revoked };
  });
  gate;
};

func sizes(gate : Gateway.Gateway) : (Nat, Nat, Nat) {
  let s = gate.toStable();
  let revoked = switch (s.accessGrants) {
    case (?g) { switch (g.revokedGrantTimestamps) { case (?t) { t.size() }; case (null) { 0 } } };
    case (null) { 0 };
  };
  (s.policy.dailySpendEntries.size(), s.policy.rateLimitEntries.size(), revoked);
};

suite("Gateway.runMaintenance", func() {
  test("removes the stale entries of all three maps and keeps the live ones", func() {
    let gate = gatewayWith(
      Array.append(Array.append(staleDaily(3), [("not-a-day:p", 1)]), liveDaily),
      Array.append(staleRate(4), liveRate),
      Array.append(staleGrants(2), liveGrants),
    );
    let r = gate.runMaintenance();
    assert r.dailySpendRemoved == 4; // 3 from yesterday + the malformed key
    assert r.rateLimitRemoved == 4;
    assert r.revokedGrantsRemoved == 2;
    assert not r.more;
    assert sizes(gate) == (1, 1, 1);
    // Nothing left to do: a second call removes nothing.
    let again = gate.runMaintenance();
    assert again.dailySpendRemoved == 0 and again.rateLimitRemoved == 0 and again.revokedGrantsRemoved == 0;
    assert not again.more;
  });

  test("on empty state it returns zeros and does not trap", func() {
    let r = Gateway.Gateway(config, owner).runMaintenance();
    assert r.dailySpendRemoved == 0 and r.rateLimitRemoved == 0 and r.revokedGrantsRemoved == 0;
    assert not r.more;
  });

  // One map over the cap at a time, so `more` is pinned to each map's own result.
  test("daily spend: stops at the cap (10,000 per call) and says more; the next call finishes", func() {
    assert Gateway.maintenanceCapPerMap == 10_000;
    let gate = gatewayWith(Array.append(staleDaily(10_001), liveDaily), [], []);
    let first = gate.runMaintenance();
    assert first.dailySpendRemoved == 10_000 and first.more;
    let second = gate.runMaintenance();
    assert second.dailySpendRemoved == 1 and not second.more;
    assert sizes(gate) == (1, 0, 0);
  });

  test("rate limit: stops at the cap and says more; the next call finishes", func() {
    let gate = gatewayWith([], Array.append(staleRate(10_001), liveRate), []);
    let first = gate.runMaintenance();
    assert first.rateLimitRemoved == 10_000 and first.more;
    let second = gate.runMaintenance();
    assert second.rateLimitRemoved == 1 and not second.more;
    assert sizes(gate) == (0, 1, 0);
  });

  test("revoked grants: stops at the cap and says more; the next call finishes", func() {
    let gate = gatewayWith([], [], Array.append(staleGrants(10_001), liveGrants));
    let first = gate.runMaintenance();
    assert first.revokedGrantsRemoved == 10_000 and first.more;
    let second = gate.runMaintenance();
    assert second.revokedGrantsRemoved == 1 and not second.more;
    assert sizes(gate) == (0, 0, 1);
  });

  test("exactly the cap's worth of stale entries is not 'more'", func() {
    let gate = gatewayWith([], staleRate(10_000), []);
    let r = gate.runMaintenance();
    assert r.rateLimitRemoved == 10_000;
    assert not r.more;
  });
});

suite("bounded clean-ups behind it (Policy, Grants)", func() {
  test("Policy.gcDailySpendUpTo: removes up to the limit, then the rest", func() {
    let p = Policy.Engine();
    let s = p.toStable();
    p.loadStable({ s with dailySpendEntries = Array.append(staleDaily(3), liveDaily) });
    assert p.gcDailySpendUpTo(2) == { removed = 2; more = true };
    assert p.gcDailySpendUpTo(2) == { removed = 1; more = false };
    assert p.toStable().dailySpendEntries == liveDaily;
  });

  test("Policy.gcRateLimitUpTo: removes up to the limit, then the rest", func() {
    let p = Policy.Engine();
    let s = p.toStable();
    p.loadStable({ s with rateLimitEntries = Array.append(staleRate(3), liveRate) });
    assert p.gcRateLimitUpTo(2) == { removed = 2; more = true };
    assert p.gcRateLimitUpTo(2) == { removed = 1; more = false };
    assert p.rateLimitEntryCount() == 1;
  });

  test("Grants.gcRevokedGrantsUpTo: removes up to the limit, then the rest", func() {
    let g = Grants.Grants(owner);
    g.loadStable({ g.toStable() with revokedGrantTimestamps = ?Array.append(staleGrants(3), liveGrants) });
    assert g.gcRevokedGrantsUpTo(2) == { removed = 2; more = true };
    assert g.gcRevokedGrantsUpTo(2) == { removed = 1; more = false };
    assert g.toStable().revokedGrantTimestamps == ?liveGrants;
  });

  test("the unbounded clean-ups the hourly timer runs still remove everything stale", func() {
    let p = Policy.Engine();
    let s = p.toStable();
    p.loadStable({
      s with
      dailySpendEntries = Array.append(staleDaily(3), liveDaily);
      rateLimitEntries = Array.append(staleRate(3), liveRate);
    });
    p.gcDailySpend();
    p.gcRateLimit();
    assert p.toStable().dailySpendEntries == liveDaily;
    assert p.rateLimitEntryCount() == 1;
    let g = Grants.Grants(owner);
    g.loadStable({ g.toStable() with revokedGrantTimestamps = ?Array.append(staleGrants(3), liveGrants) });
    g.gcRevokedGrants();
    assert g.toStable().revokedGrantTimestamps == ?liveGrants;
  });
});
