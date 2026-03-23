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
  const positional: string[] = [];

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--env' && i + 1 < args.length) {
      env = args[++i];
    } else if (args[i] === '--canister-id' && i + 1 < args.length) {
      canisterId = args[++i];
    } else if (args[i] === '--host' && i + 1 < args.length) {
      host = args[++i];
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
        console.error('  Run: pnpm setup');
        process.exit(1);
      }
    }
  }

  // Resolve the MCP server entry point (sibling package)
  const __dirname = dirname(fileURLToPath(import.meta.url));
  const serverPath = resolve(__dirname, '../../mcp/dist/index.js');

  console.log('\x1b[1m\x1b[36m');
  console.log('  ic402 Interactive Demo');
  console.log('  ─────────────────────');
  console.log(`\x1b[0m\x1b[2m  Environment: ${env}`);
  console.log(`  MCP server:  ${serverPath}`);
  console.log(`  Canister:    ${canisterId}`);
  console.log(`  Host:        ${host}\x1b[0m`);

  // Spawn the MCP server as a subprocess (inherit env for ICP_IDENTITY_PEM)
  const transport = new StdioClientTransport({
    command: 'node',
    args: [serverPath],
    env: Object.fromEntries(
      Object.entries(process.env).filter((e): e is [string, string] => e[1] != null),
    ),
  });

  const client = new Client({ name: 'ic402-demo', version: '0.1.0' });
  await client.connect(transport);

  try {
    // Verify connection by listing tools
    const { tools } = await client.listTools();
    console.log(`\x1b[2m  Connected — ${tools.length} MCP tools available\x1b[0m`);

    const steps = buildSteps(client, canisterId, host);
    await runSteps(steps);
  } finally {
    await client.close();
  }
}

main().catch((err) => {
  console.error('Fatal:', err);
  process.exit(1);
});
