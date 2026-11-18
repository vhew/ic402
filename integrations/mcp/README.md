# @ic402/mcp

An [MCP](https://modelcontextprotocol.io) (Model Context Protocol) server that exposes an
ic402-enabled ICP canister to an AI agent over **stdio**. It lets a model probe x402-gated
endpoints, open and settle streaming micropayment sessions, fetch encrypted content, drive the
ERC-8004 / marketplace flows, and — when an operator explicitly opts in — perform
controller-gated admin and signing actions.

The server identifies itself to MCP clients as:

```
name:    ic402
version: (tracks the @ic402/mcp package version)
```

(see the `new McpServer({ name, version }, { instructions })` registration in `src/index.ts`).

> **Security note up front.** This server is driven by an LLM whose inputs may be influenced by
> untrusted web content (prompt injection) while it holds a controller identity capable of
> signing value transfers from the canister's own EVM address. The security posture is therefore
> **operator-set, out-of-band** — see [Security model](#security-model). The LLM cannot loosen it.

## Build & run

The package builds with plain `tsc` (output goes to `dist/`, with `dist/index.js` as the
`ic402-mcp` bin):

```bash
# From the repo root — builds the client SDK, this MCP server, and the demo client:
pnpm build:demo

# Or build just this package (after the @ic402/client workspace dep is built):
pnpm --filter @ic402/mcp build
```

Run it directly over stdio:

```bash
node integrations/mcp/dist/index.js
# or, after build, the bin:
ic402-mcp
```

It speaks MCP JSON-RPC on **stdout** and prints diagnostics (including the security banner) to
**stderr**, so stdout is never polluted.

### Register with an MCP client

Point your MCP client at the built entrypoint, passing operator config via env vars and/or a
config file (see below). For example:

```json
{
  "mcpServers": {
    "ic402": {
      "command": "node",
      "args": ["/abs/path/to/ic402/integrations/mcp/dist/index.js"],
      "env": {
        "IC402_MCP_CANISTER_ID": "<your-canister-principal>",
        "IC402_MCP_HOST": "https://icp-api.io",
        "IC402_MCP_PER_CALL_MAX_ATOMIC": "1000000",
        "IC402_MCP_SESSION_MAX_ATOMIC": "5000000"
      }
    }
  }
}
```

You can also pass `--config <path>` (or `IC402_MCP_CONFIG=<path>`) to load a JSON config file.

## Configuration

### The `configure` tool

`configure` must be called before any other tool — every other tool throws
`Not configured. Call the "configure" tool first.` until an agent and client exist. It connects
to the operator's canister and loads the operator's signing identity:

| Param | Type | Default | Purpose |
|---|---|---|---|
| `canisterId` | string? | operator (`IC402_MCP_CANISTER_ID`) | Principal of the canister to interact with. |
| `host` | string? | operator (`IC402_MCP_HOST`, else `http://localhost:4944`) | ICP replica URL. The root key is fetched only with `localDev` and an exact `localhost` / `127.0.0.1` / `[::1]` host. |
| `network` | string | `icp:1` | CAIP-2 network identifier. |
| `identityPem` | string? | operator (`ICP_IDENTITY_PEM`), else anonymous | Path to a secp256k1 PEM (SEC1 `EC PRIVATE KEY` or PKCS#8 `PRIVATE KEY`). |
| `ledger` | string? | — | ICRC-2 ledger canister ID for auto-payment (e.g. ckUSDC). |
| `autoPayment` | boolean | `false` | Allow paid endpoints to auto-approve/pay (opt-in). |
| `localDev` | boolean | `false` | Allow `http://localhost` / private / loopback fetch targets (local development only). |
| `perCallMaxAtomic` | string? | — | Per-call max spend in atomic token units. |
| `sessionMaxAtomic` | string? | — | Cumulative session max spend in atomic token units. |

The identity loader surfaces failures loudly: if `identityPem` is supplied but cannot be parsed
(unsupported PEM, missing secp256k1 OID, wrong key length), `configure` throws rather than
silently falling back to anonymous.

**The four security knobs (`autoPayment`, `localDev`, `perCallMaxAtomic`, `sessionMaxAtomic`)
and the three connection params (`canisterId`, `host`, `identityPem`) are only honored when the
operator enabled `allowSecurityChanges` at startup.** Otherwise they are *ignored* — the
operator/default config stands — and the `configure` result reports which fields were dropped
(without an operator canister, `configure` fails), e.g.:

```
IGNORED security params ["autoPayment","perCallMaxAtomic"] — operator did not enable
LLM security changes (set IC402_MCP_ALLOW_SECURITY_CHANGES=1 to allow).
```

This stops a prompt-injected model from raising its own caps, enabling `localDev` / auto-pay, or
pointing the server at another replica, canister or key file through the `configure` tool
(`resolveSecurityConfig` / `resolveConnection` in `guards.ts`). A tool's per-call `canisterId`
must likewise name the configured canister unless `allowSecurityChanges` is set
(`resolveTargetCanister`).

### Operator config (out-of-band) — startup only

The real security boundary is resolved once, in `main()`, from an **optional JSON config file +
environment variables — both inputs the LLM cannot influence**. Precedence is:

> built-in defaults  <  config file  <  env vars  (env wins)

A config file is loaded from `--config <path>` or `IC402_MCP_CONFIG`. Unparseable amount values
fall back to the lower-precedence source rather than crashing the server (`resolveOperatorConfig`
in `guards.ts`).

#### Environment flags

| Env var | Config file key | Gates |
|---|---|---|
| `IC402_MCP_CONFIG` | — | Path to the JSON config file (alt: `--config <path>`). |
| `IC402_MCP_CANISTER_ID` | `canisterId` | The ic402 canister the server talks to. Required unless `allowSecurityChanges` lets `configure` set it. |
| `IC402_MCP_HOST` | `host` | ICP replica / gateway URL. Default `http://localhost:4944`. |
| `ICP_IDENTITY_PEM` | `identityPem` | Path to the signing identity PEM. Default: anonymous. |
| `IC402_MCP_PER_CALL_MAX_ATOMIC` | `perCallMaxAtomic` | Per-call spend cap in atomic units. Default `1_000_000` (1.00 USDC at 6 decimals). |
| `IC402_MCP_SESSION_MAX_ATOMIC` | `sessionMaxAtomic` | Cumulative session spend cap. Default `5_000_000` (5.00 USDC). |
| `IC402_MCP_LOCAL_DEV` | `localDev` | Allow `http://localhost` / private / loopback fetch targets, and fetch a local replica's root key. Default `false`. |
| `IC402_MCP_AUTO_PAYMENT` | `autoPayment` | Allow paid endpoints to auto-approve/pay. Default `false`. |
| `IC402_MCP_ALLOW_SECURITY_CHANGES` | `allowSecurityChanges` | If set, the LLM may retune caps / `localDev` / `autoPayment` and change the canister / host / identity via the `configure` tool (and a per-call `canisterId`). Default `false`. |
| `IC402_MCP_ALLOW_DANGEROUS_TOOLS` | `allowDangerousTools` | If set, enables the default-denied dangerous tools `sign_typed_data` and `delete_content`. Default `false`. |
| `IC402_MCP_ALLOW_ADMIN_TOOLS` | `allowAdminTools` | If set, enables the default-denied state-changing admin tools (`register_service`, `enable_service`, `claim_job`, `submit_job_result`, `upload_content`). Default `false` (SEC-3). |

Booleans are true when the value is exactly `"1"` or `"true"`. Amounts are parsed as
non-negative integer **strings** (a JS number that has already lost precision is rejected — see
`parseAtomicAmount`).


## Tool inventory

All tools are registered in `src/index.ts` via `server.tool(...)` (and `adminTool(...)` for the
controller-gated set).

### Read-only / query tools

- **`call`** — a generic escape hatch for **allowlisted** read methods on the canister. Signing
  and admin methods are blocked here; use the dedicated tool instead. **Exception:**
  `getContent` / `getAssetContent` / `getExternalContent` called *with* a PaymentSignature settle
  a payment from an ICRC-2 allowance the payer already granted — no spend cap, no confirmation.
  The allowlist and blocklist are detailed under
  [The `call` allowlist & blocklist](#the-call-allowlist--blocklist).
- **`list_services`** — list available paid services from the canister.
- **`request_session`** — request a session intent (pricing: `suggestedDeposit`, `costPerCall`)
  *without* opening a session.
- **`get_session`** — state of an active session (consumed, remaining, voucher count).
- **`list_sessions`** — list all active sessions managed by this server.
- **`get_job_result`** — poll for a job result until it completes or times out.
- **`session_query`** — send a query through an open session (auto-signs a voucher). Each call
  consumes `costPerCall` from the already-escrowed deposit, so it is not separately confirm-gated.
- **`search`** — call the canister's `search` endpoint (x402 charge flow); returns results or a
  payment requirement.
- **`dispute_job`** — dispute a job result (for `BuyerConfirm` verification services).

### Payment / session tools (capped + confirmation-gated)

These move or settle value, so they enforce the spend caps and require an explicit `confirm:true`
(when `confirm` is `false` they return a structured `confirmation_required` proposal describing
amount / recipient / asset / chain):

- **`fetch_x402`** — full x402 flow: probe a gated URL → canister signs the payment → retry with
  the payment header. Probe-only when `confirm:false`; signing the proposed payment requires
  `confirm:true` **plus the proposal's `amount`, `recipient`, `asset` and `chain`** (returned as
  `confirmWith`) — the re-probe is refused if the server's terms changed. Pays only USDC on the
  supported chains (`X402_USDC_BY_CHAIN` in `guards.ts`). SSRF-guarded on the URL and every
  redirect hop (literal host + DNS), with a capped body read.
- **`fetch_content`** — fetch content from a `ContentDelivery` response. Supports `inline`,
  `httpUrl` (SSRF-guarded `safeFetch`), `assetCanister` (validated canister id + URL-API origin),
  and `canisterQuery` (restricted to the `getChunk` / `getContent` query methods).
- **`open_session`** — open a streaming micropayment session. ICP uses ICRC-2 escrow; EVM takes
  an `evmTxHash` (and EIP-3009 `authorization`) proving the USDC deposit. The escrow deposit is
  capped + confirmed, counted against the cumulative cap, and passed to the client as
  `maxDeposit` (the most it approves and the canister pulls).
- **`close_session`** — settle the consumed amount on-chain and refund the remainder; returns a
  payment receipt. Requires `confirm:true` (the consumed amount was already counted at deposit
  time, so it is not re-charged against the cap).
- **`submit_request`** — submit a paid service request. If the service demands payment, the
  operator must have opted into `autoPayment` *and* the caller must pass `confirm:true` after
  reviewing the amount. The price is discovered via a **read-only** `quoteServiceRequest` query
  (no nonce minted), and the cap is checked against the **total** (price + ledger fee), not the
  bare price. The confirmed total is passed to the client as `maxAmount`, so the update call
  cannot make it approve more; `paidAmount` is what the client actually paid. Free /
  session-billed services (total `0`) submit with `maxAmount: 0` — refused if the canister then
  demands payment.
- **`register_agent`** — register the canister as an ERC-8004 agent on Base: get nonce + gas →
  canister signs → broadcast → poll receipt. Broadcasting spends native gas, so it is
  confirm-gated (no USDC amount, hence no spend cap); a custom `rpcUrl` is SSRF-validated.

### State-changing / signing tools (the 7 operator tools)

Registered via `adminTool(...)`, each binds a **fixed** controller-gated canister method (the LLM
cannot choose the method) and requires `confirm:true`:

| Tool | Canister method | Notes |
|---|---|---|
| `upload_content` | `uploadContent` | Upload + encrypt content into the ContentStore (controller-gated). |
| `delete_content` | `deleteContent` | Destructive delete. **DEFAULT-DENIED** — see below. |
| `register_service` | `registerService` | Register a paid marketplace service (controller-gated). |
| `enable_service` | `enableService` | Enable a registered service so it can accept paid requests. |
| `claim_job` | `claimJob` | Operator claims a pending marketplace job. |
| `submit_job_result` | `submitJobResult` | Operator submits a job result (+ optional proof) for verification + settlement. |
| `sign_typed_data` | `signTypedData` | Sign arbitrary EIP-712 typed data with the canister tECDSA key. **DEFAULT-DENIED** — generic signing primitive. |

**Default-denied tools (operator opt-in required).** Two categories throw unless the operator
enables them at startup — a prompt-injected LLM must not reach them via an in-band `confirm` alone:

- **Dangerous primitives** — `sign_typed_data` (a raw EIP-712 signing oracle that can authorize an
  arbitrary-value transfer and *bypasses the spend caps*) and `delete_content` (irreversible delete).
  Enable with `IC402_MCP_ALLOW_DANGEROUS_TOOLS=1`.
- **State-changing admin tools (SEC-3)** — `register_service`, `enable_service`, `claim_job`,
  `submit_job_result`, `upload_content` mutate the canister and drive the value-moving job lifecycle.
  Enable with `IC402_MCP_ALLOW_ADMIN_TOOLS=1`.

(`isToolAllowed` / `DANGEROUS_TOOLS` / `ADMIN_TOOLS` in `guards.ts`.)

## Security model

The server assumes the LLM driving it may be steered by untrusted web content while it holds a
controller identity that can sign value transfers from the canister's own EVM address. Every
money-moving or signing path is therefore capped, SSRF-guarded, and gated behind explicit
confirmation.

### Spend caps — per-call and cumulative

Two caps, in atomic token units (USDC has 6 decimals, so `1_000_000` atomic = 1.00 USDC):

- **`perCallMaxAtomic`** — caps a single signed transfer (default `1_000_000` = 1.00 USDC).
- **`sessionMaxAtomic`** — caps the cumulative total spent/approved across this server session
  (default `5_000_000` = 5.00 USDC).

`checkSpend` (in `guards.ts`) rejects negative amounts, any single amount over the per-call cap,
and any amount that would push the running session total over the cumulative cap. The running
total (`sessionSpentAtomic`) is reserved at confirm time and released only when the client
proves no payment was sent (`Ic402Error.paymentNotSent`: price above the ceiling, approve
`#Err`, the unpaid request refused — `reservationReleasable` in `guards.ts`); a timeout or any
error after the paying call keeps it. The conservative defaults force the LLM to stay within a
trivial budget unless a human raises the caps out-of-band (and only when `allowSecurityChanges`
is set).

### Explicit confirmation gating

Money-moving / signing tools route through `requireConfirmation`, which **enforces the caps
first** (so an over-cap action is refused even before any confirmation) and then, when
`confirm:false`, returns a structured `confirmation_required` result echoing the proposed
`amount` / `recipient` / `asset` / `chain` plus the current caps and instructs the caller to
re-invoke with `confirm:true`. The instruction explicitly says *"Do NOT confirm automatically."*

### Operator-only escalation

The security boundary is resolved at startup from a config file + env vars the LLM cannot touch
(see [Operator config](#operator-config-out-of-band--startup-only)). The `configure` tool can
loosen caps / `localDev` / `autoPayment`, or change the canister / host / identity, **only** when
`allowSecurityChanges` is enabled; otherwise those request fields are ignored and reported. The two dangerous tools stay off unless
`allowDangerousTools` is enabled.

### SSRF guard (and a known limitation)

Every outbound fetch path (`fetch_x402`, the `httpUrl` / `assetCanister` deliveries in
`fetch_content`, and any custom `rpcUrl`) is validated by `validateFetchUrl` and uses the
redirect-safe `safeFetch` (both in `security.ts`):

- Requires `https:` (or `http://localhost` / `127.0.0.1` / `::1` only when `localDev` is set).
- Rejects literal private / loopback / link-local / CGNAT / reserved IPv4 ranges (10/8,
  172.16/12, 192.168/16, 127/8, 169.254/16, 100.64/10, 0/8, 198.18/15, 240/4), the
  `169.254.169.254` cloud-metadata endpoint, private/loopback/link-local IPv6 literals, IPv6 forms
  that embed a private IPv4 (IPv4-mapped `::ffff:`, NAT64 `64:ff9b::/96`, 6to4 `2002::/16`), and
  `.local` / `.internal` TLDs. Hostnames are never read as IPv6 (`fda.gov` is allowed).
- `safeFetch` follows redirects **manually** (default max 5) and **re-validates every hop's
  `Location` — literal host and DNS — before following it**, closing the TOCTOU redirect-bypass
  where an allowlisted origin 30x's to an internal/metadata target. The x402 probe goes through
  `safeFetch` too (`probeChallenge`).
- Fetched bodies (the x402 probe, the paid response, `fetch_content` downloads) are read up to
  10 MiB (`readTextCapped`); a larger body is refused.

> **Residual — check-vs-connect rebinding window.** DNS rebinding is closed: `safeFetch` resolves
> every host and every redirect hop and rejects the request if *any* resolved address is
> private/loopback/link-local/metadata (`assertResolvedHostIsPublic`, the SEC-0 fix). What remains is
> a narrow TOCTOU window — the OS re-resolves at connection time, so a name that flips to an internal
> IP between the check and the connect is not caught. Fully closing it requires pinning the validated
> IP at the connection layer (a custom undici dispatcher); noted in `security.ts`.

### The `call` allowlist & blocklist

The generic `call` tool is restricted to read methods by `isCallMethodAllowed` in `guards.ts`
(the get-prefix fallback admits the dual-mode `getContent` / `getAssetContent` /
`getExternalContent`, which settle a payment when passed a PaymentSignature — see the tool
description):

1. **Curated read-only allowlist (authoritative):** `listContent`, `getChunk`, `getAgentCard`,
   `getAgentId`, `verifyGrant`, `listServices`, `getJobStatus`, `getJob`, `getJobResult`,
   `keccak256`, `getPolicyConfig`. These are accepted even if their name contains a blocked
   substring (`getPolicyConfig` contains `policy`).
2. **Hard blocklist of substrings** that denote signing/admin/value-moving methods (each has a
   dedicated tool): `sign`, `set`, `submit`, `open`, `close`, `transfer`, `register`, `pay`,
   `approve`, `policy`, `upload`, `delete`, `claim`, `confirm`, `dispute`, `enable`, `disable`,
   `end`. Any method whose name contains one of these is rejected.
3. **Forward-compat fallback:** after the blocklist clears a name, read-only getter prefixes
   (`get…`, `list…`, `fetch…`, `is…`) are allowed. Anything else is rejected with a message
   pointing the LLM at the dedicated, capped, confirmation-gated tool.

### Startup security banner

On startup the server prints the **effective** security posture to **stderr** (stdout is the MCP
JSON-RPC channel) so the operator can verify what's active before the agent connects. The banner
shows the config source (config file path or `env vars / defaults`), the host / canister /
identity, `perCallMaxAtomic`, `sessionMaxAtomic`, `localDev`, `autoPayment`,
`allowSecurityChanges`, and `allowDangerousTools`, and warns when any loosened knob is enabled:

```
───────────────────────────────────────────────────────────────
 ic402 MCP — effective security config (operator-set, out-of-band)
   source                 : env vars / defaults
   host                   : https://icp-api.io
   canisterId             : rrkah-fqaaa-aaaaa-aaaaq-cai
   identity               : /abs/path/to/identity.pem
   perCallMaxAtomic       : 1000000
   sessionMaxAtomic       : 5000000
   localDev               : false
   autoPayment            : false
   allowSecurityChanges   : false  (LLM may retune caps / host / canister / identity via "configure")
   allowDangerousTools    : false  (sign_typed_data / delete_content)
───────────────────────────────────────────────────────────────
```

When `allowSecurityChanges` or `allowDangerousTools` is enabled, the banner adds:

```
   ⚠  a loosened knob is enabled — only do this in a TRUSTED context (no prompt-injection risk).
```

## Source layout

- `src/index.ts` — `McpServer` registration, all tool definitions, the `configure` flow, the
  confirmation gate, the `call` allowlist/blocklist, the `adminTool` helper, and `main()`
  (operator-config resolution + security banner + stdio transport).
- `src/guards.ts` — pure, unit-tested guards: `parseAtomicAmount`, `checkSpend`,
  `resolveSecurityConfig`, `isToolAllowed` / `DANGEROUS_TOOLS`, `resolveOperatorConfig`.
- `src/security.ts` — pure SSRF validation (`validateFetchUrl` and the IPv4/IPv6 helpers) and the
  redirect-safe `safeFetch`.
- `package.json` — `@ic402/mcp` package metadata; `build` runs `tsc`, `start` runs `node dist/index.js`,
  and the `ic402-mcp` bin maps to `dist/index.js`.
