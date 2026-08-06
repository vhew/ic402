#!/usr/bin/env node

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { runSteps } from './runner.js';
import { buildSteps } from './steps.js';

const USAGE = `
Usage: node dist/index.js [options] [canister-id] [host]

Options:
  --env local|ic    Environment (default: local)
  --canister-id     Canister principal (auto-detected for local)
  --host            ICP replica URL (auto-set per environment)
  -h, --help        Show this help

Examples:
  node dist/index.js                                  # local (auto-detect)
  node dist/index.js --env ic                         # production (uses CANISTER_ID env)
  node dist/index.js --env ic --canister-id abc-123   # production with explicit ID
  node dist/index.js t63gs-up777-77776-aaaba-cai      # legacy positional args
`;

async function main(): Promise<void> {
  const args = process.argv.slice(2);

  if (args.includes('--help') || args.includes('-h')) {
    console.log(USAGE);
    process.exit(0);
  }

  // Parse named arguments
  let env = 'local';
  let canisterId = '';
  let host = '';
  // Non-interactive "smoke test" mode: run every step without prompting and exit non-zero
  // if any step failed. Enabled by --ci/--non-interactive/--yes or CI / IC402_DEMO_CI env.
  let nonInteractive =
    process.env.CI === '1' || process.env.CI === 'true' || process.env.IC402_DEMO_CI === '1';
  const positional: string[] = [];

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--env' && i + 1 < args.length) {
      env = args[++i];
    } else if (args[i] === '--canister-id' && i + 1 < args.length) {
      canisterId = args[++i];
    } else if (args[i] === '--host' && i + 1 < args.length) {
      host = args[++i];
    } else if (args[i] === '--ci' || args[i] === '--non-interactive' || args[i] === '--yes') {
      nonInteractive = true;
    } else if (!args[i].startsWith('--')) {
      positional.push(args[i]);
    }
  }

  // Legacy positional args: <canister-id> [host]
  if (positional.length >= 1 && !canisterId) canisterId = positional[0];
  if (positional.length >= 2 && !host) host = positional[1];

  // Apply environment defaults
  if (env === 'ic') {
    if (!canisterId) canisterId = process.env.CANISTER_ID ?? '';
    if (!host) host = 'https://icp-api.io';
    if (!canisterId) {
      console.error('ERROR: Production mode requires a canister ID.');
      console.error('  Set CANISTER_ID env var or pass --canister-id <id>');
      process.exit(1);
    }
  } else {
    if (!host) host = 'http://localhost:4944';
    // Auto-detect local canister ID if not provided
    if (!canisterId) {
      try {
        const { execSync } = await import('node:child_process');
        canisterId = execSync('icp canister status example -e local --id-only', {
          encoding: 'utf-8',
          stdio: ['pipe', 'pipe', 'pipe'],
        }).trim();
      } catch {
        console.error('ERROR: Could not detect local canister ID.');
        console.error('  Run: pnpm setup:local');
        process.exit(1);
      }
    }
    // Auto-detect local ckUSDC ledger ID
    if (!process.env.CKUSDC_LEDGER) {
      try {
        const { execSync } = await import('node:child_process');
        process.env.CKUSDC_LEDGER = execSync(
          'icp canister status ckusdc_ledger -e local --id-only',
          {
            encoding: 'utf-8',
            stdio: ['pipe', 'pipe', 'pipe'],
          },
        ).trim();
      } catch {
        /* use default */
      }
    }
  }

  // Resolve the MCP server entry point
  const __dirname = dirname(fileURLToPath(import.meta.url));
  const serverPath = resolve(__dirname, '../../../integrations/mcp/dist/index.js');

  console.log('\x1b[1m\x1b[36m');
  console.log('  ic402 Interactive Demo');
  console.log('  ─────────────────────');
  console.log(`\x1b[0m\x1b[2m  Environment: ${env}`);
  console.log(`  MCP server:  ${serverPath}`);
  console.log(`  Canister:    ${canisterId}`);
  console.log(`  Host:        ${host}\x1b[0m`);

  // Spawn the MCP server as a subprocess (inherit env for ICP_IDENTITY_PEM).
  // The demo is a trusted, operator-run context that deliberately exercises the
  // dangerous MCP primitives (sign_typed_data, delete_content) and configure({localDev}),
  // so it opts in explicitly. Production deployments must NOT set these — the MCP defaults
  // them off so a prompt-injected LLM cannot reach a raw signing oracle or raise its own
  // caps (audit S1/S8/S9).
  const transport = new StdioClientTransport({
    command: 'node',
    args: [serverPath],
    env: {
      ...Object.fromEntries(
        Object.entries(process.env).filter((e): e is [string, string] => e[1] != null),
      ),
      IC402_MCP_ALLOW_SECURITY_CHANGES: '1',
      IC402_MCP_ALLOW_DANGEROUS_TOOLS: '1',
      // SEC-3: the demo drives the state-changing admin tools (upload_content, register_service,
      // claim_job, …), which are now default-denied — opt in explicitly (trusted demo context).
      IC402_MCP_ALLOW_ADMIN_TOOLS: '1',
    },
  });

  const client = new Client({ name: 'ic402-demo', version: '2.13.1' });
  await client.connect(transport);

  try {
    // Verify connection by listing tools
    const { tools } = await client.listTools();
    console.log(`\x1b[2m  Connected — ${tools.length} MCP tools available\x1b[0m`);

    const steps = buildSteps(client, canisterId, host);
    if (nonInteractive) {
      console.log(
        `\x1b[2m  Non-interactive smoke-test mode — running all ${steps.length} steps\x1b[0m`,
      );
    }
    const summary = await runSteps(steps, { autoRun: nonInteractive });
    if (summary.failed > 0) {
      console.error(
        `\x1b[31m  ${summary.failed} step(s) FAILED: ${summary.failedNames.join(', ')}\x1b[0m`,
      );
    }
  } finally {
    await client.close();
  }
}

main().catch((err) => {
  console.error('Fatal:', err);
  process.exit(1);
});
