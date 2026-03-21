#!/usr/bin/env node

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { runSteps } from './runner.js';
import { buildSteps } from './steps.js';

const USAGE = `
Usage: node dist/index.js <canister-id> [host]

  canister-id   Principal of the deployed example canister
  host          ICP replica URL (default: http://localhost:4944)

Example:
  CANISTER_ID=$(icp canister status example -e local --id-only)
  node dist/index.js $CANISTER_ID http://localhost:4944
`;

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  if (args.length < 1 || args.includes('--help') || args.includes('-h')) {
    console.log(USAGE);
    process.exit(args.includes('--help') || args.includes('-h') ? 0 : 1);
  }

  const canisterId = args[0];
  const host = args[1] ?? 'http://localhost:4944';

  // Resolve the MCP server entry point (sibling package)
  const __dirname = dirname(fileURLToPath(import.meta.url));
  const serverPath = resolve(__dirname, '../../mcp/dist/index.js');

  console.log('\x1b[1m\x1b[36m');
  console.log('  ic402 Interactive Demo');
  console.log('  ─────────────────────');
  console.log(`\x1b[0m\x1b[2m  MCP server: ${serverPath}`);
  console.log(`  Canister:   ${canisterId}`);
  console.log(`  Host:       ${host}\x1b[0m`);

  // Spawn the MCP server as a subprocess
  const transport = new StdioClientTransport({
    command: 'node',
    args: [serverPath],
  });

  const client = new Client({ name: 'ic402-demo', version: '0.1.0' });
  await client.connect(transport);

  try {
    // Verify connection by listing tools
    const { tools } = await client.listTools();
    console.log(
      `\x1b[2m  Connected — ${tools.length} MCP tools available\x1b[0m`,
    );

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
