# Give your agent a wallet: installing `@ic402/mcp`

`@ic402/mcp` is an [MCP](https://modelcontextprotocol.io) (Model Context Protocol) server that
connects an AI agent to an [ic402](https://github.com/vhew/ic402)-enabled ICP canister over
**stdio** — and, through that canister, to the x402 payment web. Once connected, your agent can
probe x402-gated APIs and pay for them (USDC on 5 EVM chains: Base, Ethereum, Avalanche,
Optimism, Arbitrum — plus ICRC-2 tokens like ckUSDC on ICP), open streaming micropayment
sessions, buy encrypted gated content, drive a paid-services marketplace, and register itself as
an ERC-8004 agent on Base.

Every money-moving action is **capped and confirmation-gated by default** (per-call cap 1.00
USDC, cumulative session cap 5.00 USDC), and the security posture is set by the *operator* via
env vars / a config file — the LLM cannot loosen it. See
[security-model.md](security-model.md) for the full threat model.

---

## 1. Install / connect

### Prerequisites

- **Node.js** — a recent LTS release. <!-- TODO(maintainer): package.json declares no `engines`
  field; pin and document the minimum supported Node version. -->
- **An ic402-enabled canister to talk to.** Either a canister you deployed with the
  [ic402 Motoko library](getting-started.md), or a local dev deployment
  (`pnpm setup:local` in this repo).
- **Optional: a signing identity.** A secp256k1 PEM file (SEC1 `EC PRIVATE KEY` or PKCS#8
  `PRIVATE KEY`, e.g. from `icp identity export`). Without one, the agent connects anonymously —
  fine for probing prices, required for controller-gated actions.

### The command

The package ships one binary, `ic402-mcp` (from `bin` in
[`integrations/mcp/package.json`](../integrations/mcp/package.json)), which maps to
`dist/index.js`. Three equivalent ways to run it:

```bash
# 1. Straight from npm (no install) — npx runs the package's only bin:
npx -y @ic402/mcp

# 2. Global install:
npm install -g @ic402/mcp
ic402-mcp

# 3. From a source checkout (builds @ic402/client + the server):
pnpm build:demo
node /abs/path/to/ic402/integrations/mcp/dist/index.js
```

The server speaks MCP JSON-RPC on **stdout** and prints diagnostics — including a startup
security banner showing the effective caps and flags — on **stderr**.

It accepts one CLI flag, `--config <path>`, pointing at a JSON operator-config file
(equivalently: the `IC402_MCP_CONFIG` env var). Everything else is env vars — see
[Operator configuration](#operator-configuration-env-vars) below.

### Claude Desktop

Edit `claude_desktop_config.json` (macOS: `~/Library/Application Support/Claude/`;
Windows: `%APPDATA%\Claude\`) and add:

```json
{
  "mcpServers": {
    "ic402": {
      "command": "npx",
      "args": ["-y", "@ic402/mcp"],
      "env": {
        "IC402_MCP_CANISTER_ID": "<your-canister-principal>",
        "IC402_MCP_HOST": "https://icp-api.io",
        "ICP_IDENTITY_PEM": "/abs/path/to/identity.pem",
        "IC402_MCP_PER_CALL_MAX_ATOMIC": "1000000",
        "IC402_MCP_SESSION_MAX_ATOMIC": "5000000"
      }
    }
  }
}
```

Restart Claude Desktop; the server appears as **ic402** in the MCP tools list.

### Claude Code

```bash
claude mcp add ic402 \
  --env IC402_MCP_CANISTER_ID=<your-canister-principal> \
  --env IC402_MCP_HOST=https://icp-api.io \
  --env ICP_IDENTITY_PEM=/abs/path/to/identity.pem \
  -- npx -y @ic402/mcp
```

### Cursor

Create (or extend) `.cursor/mcp.json` in your project — or `~/.cursor/mcp.json` globally:

```json
{
  "mcpServers": {
    "ic402": {
      "command": "npx",
      "args": ["-y", "@ic402/mcp"],
      "env": {
        "IC402_MCP_CANISTER_ID": "<your-canister-principal>",
        "IC402_MCP_HOST": "https://icp-api.io",
        "ICP_IDENTITY_PEM": "/abs/path/to/identity.pem"
      }
    }
  }
}
```

### Continue

Add an MCP server block to your Continue config (`~/.continue/config.yaml`):

```yaml
mcpServers:
  - name: ic402
    command: npx
    args:
      - "-y"
      - "@ic402/mcp"
    env:
      IC402_MCP_CANISTER_ID: <your-canister-principal>
      IC402_MCP_HOST: https://icp-api.io
      ICP_IDENTITY_PEM: /abs/path/to/identity.pem
```

<!-- TODO(maintainer): verify this block against the Continue version you support — Continue's
MCP config schema has changed across releases (config.json vs config.yaml). -->

### Generic stdio client

Any MCP client that can spawn a stdio server works with:

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

(Swap `command`/`args` for `npx -y @ic402/mcp` if you installed from npm.)

### First contact: the `configure` tool

Every other tool throws `Not configured. Call the "configure" tool first.` until the agent has
connected. The canister, replica host and identity are the **operator's** (set in the server's
env above — `IC402_MCP_CANISTER_ID`, `IC402_MCP_HOST`, `ICP_IDENTITY_PEM`), so the first thing to
tell your agent is simply:

> Configure ic402 (ledger `<ckUSDC-ledger-id>` if you pay on ICP).

`configure` parameters (set by the agent in-band):

| Param | Default | Purpose |
|---|---|---|
| `network` | `icp:1` | CAIP-2 network identifier. |
| `ledger` | — | ICRC-2 ledger canister ID for auto-payment (e.g. ckUSDC). |
| `canisterId`, `host`, `identityPem` | operator config | **Connection — ignored** (and reported as ignored) unless the operator set `IC402_MCP_ALLOW_SECURITY_CHANGES=1`. Without an operator canister, `configure` fails. The root key is fetched only with `localDev` and an exact `localhost` / `127.0.0.1` / `[::1]` host. An unparseable PEM throws loudly — no silent anonymous fallback. |
| `autoPayment`, `localDev`, `perCallMaxAtomic`, `sessionMaxAtomic` | operator config | **Security knobs — ignored** (and reported as ignored) unless the operator set `IC402_MCP_ALLOW_SECURITY_CHANGES=1`. |

A tool's per-call `canisterId` must likewise name the configured canister unless the operator set
`IC402_MCP_ALLOW_SECURITY_CHANGES=1`.

### Operator configuration (env vars)

Resolved once at startup, from inputs the LLM cannot influence. Precedence:
**built-in defaults < config file (`--config` / `IC402_MCP_CONFIG`) < env vars**.
Booleans are true only for `"1"` or `"true"`; amounts are atomic-unit integer **strings**
(USDC has 6 decimals, so `1000000` = 1.00 USDC).

| Env var | Config file key | Default | Gates |
|---|---|---|---|
| `IC402_MCP_CONFIG` | — | — | Path to the JSON config file (alt: `--config <path>`). |
| `IC402_MCP_CANISTER_ID` | `canisterId` | — | The ic402 canister the server talks to. Required unless `allowSecurityChanges` lets `configure` set it. |
| `IC402_MCP_HOST` | `host` | `http://localhost:4944` | ICP replica / gateway URL. |
| `IC402_MCP_PER_CALL_MAX_ATOMIC` | `perCallMaxAtomic` | `1000000` (1.00 USDC) | Cap on a single signed transfer. |
| `IC402_MCP_SESSION_MAX_ATOMIC` | `sessionMaxAtomic` | `5000000` (5.00 USDC) | Cumulative spend cap for the server session. |
| `IC402_MCP_LOCAL_DEV` | `localDev` | `false` | Allow `http://localhost` / private / loopback fetch targets, and fetch a local replica's root key (local dev only). |
| `IC402_MCP_AUTO_PAYMENT` | `autoPayment` | `false` | Allow paid endpoints to auto-approve/pay (still capped + confirm-gated). |
| `IC402_MCP_ALLOW_SECURITY_CHANGES` | `allowSecurityChanges` | `false` | Let the LLM retune caps / `localDev` / `autoPayment` and change the canister / host / identity via `configure` (and a per-call `canisterId`). |
| `IC402_MCP_ALLOW_DANGEROUS_TOOLS` | `allowDangerousTools` | `false` | Enable `sign_typed_data` and `delete_content`. |
| `IC402_MCP_ALLOW_ADMIN_TOOLS` | `allowAdminTools` | `false` | Enable the state-changing admin tools (`register_service`, `enable_service`, `claim_job`, `submit_job_result`, `upload_content`). |
| `ICP_IDENTITY_PEM` | `identityPem` | anonymous | Path to the signing identity PEM (loaded by `configure`). |

Only loosen these in a trusted context — the startup banner on stderr warns when any loosened
knob is active.

---

## 2. What your agent can do once it can pay

The agent-facing economy runs on four flows, each mapped to concrete tools. Money-moving tools
return a structured `confirmation_required` proposal (amount / recipient / asset / chain) when
called with `confirm:false`, and only act on an explicit `confirm:true` that repeats the
proposal's `confirmWith` values — so the agent (and you) always see the price before anything is
signed, and nothing is paid if the price changed in between.

**Pay any x402 API on the open web.** `fetch_x402` runs the full flow against an x402-gated URL:
probe it, have the canister sign the USDC payment with its threshold-ECDSA key on the requested
chain (Base, Ethereum, Avalanche, Optimism, or Arbitrum), and retry with the payment header.
Called without `confirm`, it's a free price probe. Your agent can now consume paid data feeds,
inference endpoints, and search APIs that return HTTP 402 — no API keys, no accounts. It pays
only USDC, and the `confirm:true` call must repeat the proposal's amount, recipient, asset and
chain: if the server's 402 changed in between, nothing is signed. `search`
runs the same x402 charge flow against the connected canister's own paid endpoint.

**Stream micropayments instead of paying per call.** `request_session` quotes the pricing
(`suggestedDeposit`, `costPerCall`); `open_session` escrows a deposit once (ICRC-2 on ICP, or an
EIP-3009 USDC deposit on EVM); then `session_query` streams as many calls as the deposit covers,
each made as the session's own Ed25519 key (the IC verifies the caller; no in-canister signature check). `close_session` settles the consumed amount and
refunds the rest — a fixed few on-chain transactions, however many calls the deposit covers. `get_session` /
`list_sessions` track state.

**Buy gated content.** When a paid endpoint returns a `ContentDelivery` grant, `fetch_content`
redeems it — inline bytes, an SSRF-guarded HTTP URL, an ICP asset canister, or a chunked
canister query — and hands the decrypted content to the agent.

**Hire (and be hired on) a paid-services marketplace.** `list_services` discovers what the
canister sells; `submit_request` quotes the price via a read-only query, then — only with
operator-enabled `autoPayment` *and* `confirm:true` — escrows payment and submits the job;
`get_job_result` polls for the verified result; `dispute_job` contests a bad one. On the
operator side (off by default, `IC402_MCP_ALLOW_ADMIN_TOOLS=1`), the same agent can
`register_service`, `enable_service`, `claim_job`, and `submit_job_result` — i.e. *earn*, not
just spend.

**Establish an on-chain identity.** `register_agent` registers the canister as an ERC-8004 agent
on Base (confirm-gated: it broadcasts a gas-spending transaction), making it discoverable to
other agents. A generic `call` tool rounds things out for allowlisted getters
(`listServices`, `getJobStatus`, `getAgentCard`, …) — signing and admin methods are blocked there
and routed to their dedicated, gated tools. One exception moves funds: `getContent` (and
`getAssetContent` / `getExternalContent`) called *with* a PaymentSignature settles a payment from
an ICRC-2 allowance the payer already granted, with no spend cap and no confirmation.

---

## 3. Registry listing blurb

> **ic402 — payments for AI agents (x402 / ICP / 5 EVM chains).** Give your agent the ability to
> pay: probe and settle x402-gated APIs with USDC on Base, Ethereum, Avalanche, Optimism, or
> Arbitrum, open streaming micropayment sessions (deposit once, stream signed vouchers, settle on
> close), buy encrypted gated content, transact on a paid-services marketplace, and
> register an ERC-8004 agent identity on Base — all signed by an ICP canister's threshold-ECDSA
> key, so there's no private key on the agent's machine. Injection-resistant by design: per-call
> and cumulative spend caps, explicit confirm-gating on every value-moving tool, SSRF-guarded
> fetches, and an operator-set security boundary the LLM cannot loosen. Runs over stdio:
> `npx -y @ic402/mcp`.

---

## See also

- [`integrations/mcp/README.md`](../integrations/mcp/README.md) — full tool inventory, the
  `call` allowlist/blocklist, and configuration reference.
- [security-model.md](security-model.md) — threat model, spend caps, SSRF guard, known
  limitations (DNS rebinding).
- [getting-started.md](getting-started.md) — deploying an ic402-enabled canister of your own.
