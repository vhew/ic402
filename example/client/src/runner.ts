import * as readline from 'node:readline/promises';
import { stdin, stdout } from 'node:process';

const DIM = '\x1b[2m';
const RESET = '\x1b[0m';
const GREEN = '\x1b[32m';
const RED = '\x1b[31m';
const YELLOW = '\x1b[33m';
const BOLD = '\x1b[1m';

/** Thrown when the user chooses to quit from any prompt. */
export class QuitError extends Error {
  constructor() {
    super('quit');
  }
}

/**
 * Thrown by a step to report that THIS specific failure is a known issue outside ic402's
 * control (e.g. a testnet contract that rejects a valid EIP-3009 signature, or an unfunded
 * gas wallet) — reported as ⚠ (does not fail the run), without flagging the whole step
 * `knownIssue` (which would also mask a genuine ic402 bug in that step). `detail` is an
 * optional second line explaining why it is not a real failure.
 */
export class KnownIssueError extends Error {
  detail?: string;
  constructor(message: string, detail?: string) {
    super(message);
    this.detail = detail;
  }
}

export interface StepDef {
  name: string;
  description: string;
  run: (rl: readline.Interface) => Promise<void>;
  /**
   * If set, a FAILURE of this step is reported as a KNOWN ISSUE (⚠) rather than a hard
   * failure, and does NOT fail the run. Use only for steps that depend on an external
   * resource outside ic402's control (e.g. a live testnet faucet / third-party API). Leave
   * unset so genuine breakage shows as ✗ FAILED and fails the run.
   */
  knownIssue?: string;
}

export type StepStatus = 'passed' | 'failed' | 'known-issue' | 'skipped';

export interface StepResult {
  name: string;
  status: StepStatus;
  error?: string;
}

export interface RunSummary {
  total: number;
  passed: number;
  failed: number;
  knownIssues: number;
  skipped: number;
  exitCode: number;
  failedNames: string[];
}

/** Aggregate step results into a pass/fail verdict. Pure — unit-tested. */
export function summarizeResults(results: StepResult[]): RunSummary {
  const by = (s: StepStatus) => results.filter((r) => r.status === s);
  const failed = by('failed');
  return {
    total: results.length,
    passed: by('passed').length,
    failed: failed.length,
    knownIssues: by('known-issue').length,
    skipped: by('skipped').length,
    exitCode: failed.length > 0 ? 1 : 0,
    failedNames: failed.map((r) => r.name),
  };
}

function printSummary(s: RunSummary): void {
  const bar = '═'.repeat(60);
  const verdict = s.failed > 0 ? `${RED}✗ FAIL${RESET}` : `${GREEN}✓ PASS${RESET}`;
  console.log(`\n${BOLD}${bar}${RESET}`);
  console.log(`  ${BOLD}DEMO RESULT: ${verdict}${RESET}`);
  console.log(
    `  ${GREEN}✓ ${s.passed} passed${RESET}   ${RED}✗ ${s.failed} failed${RESET}   ` +
      `${YELLOW}⚠ ${s.knownIssues} known${RESET}   ${DIM}⊘ ${s.skipped} skipped${RESET}`,
  );
  if (s.failedNames.length > 0) {
    console.log(`  ${RED}Failed steps: ${s.failedNames.join(', ')}${RESET}`);
  }
  console.log(`${BOLD}${bar}${RESET}`);
}

let autoRunMode = false;

/**
 * Run a list of steps. Interactive by default (Enter / s / q per step). With opts.autoRun the
 * demo runs every step non-interactively (auto-answering in-step prompts) for use as a smoke
 * test.
 *
 * Every step's outcome is tracked and a PASS/FAIL verdict is printed at the end. A real
 * failure — a step that throws, unless it is flagged knownIssue — prints ✗ FAILED and sets a
 * non-zero process exit code, so breakage is unmissable (and the run never masks it as
 * "expected").
 */
export async function runSteps(
  steps: StepDef[],
  opts: { autoRun?: boolean } = {},
): Promise<RunSummary> {
  autoRunMode = opts.autoRun ?? false;
  const rl = readline.createInterface({ input: stdin, output: stdout });
  const results: StepResult[] = [];

  if (autoRunMode) {
    // Non-interactive: auto-answer the in-step menus (Step 3 payment method, Step 7 deposit
    // method) so nothing blocks on stdin. Default to "2" = Base Sepolia (option 1 is ICP) so a
    // non-interactive run exercises the EVM/Base on-chain settlement path (B3 verification).
    // Override with IC402_DEMO_DEFAULT_CHOICE (e.g. =1 for the ICP-only path — no testnet funds
    // needed, but it does not settle on-chain).
    const defaultAnswer = process.env.IC402_DEMO_DEFAULT_CHOICE ?? '2';
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (rl as any).question = async (q: string): Promise<string> => {
      console.log(`${DIM}${q}${defaultAnswer}${RESET}`);
      return defaultAnswer;
    };
  }

  try {
    for (let i = 0; i < steps.length; i++) {
      const step = steps[i];
      console.log(`\n${DIM}[${i + 1}/${steps.length}]${RESET} ${BOLD}${step.name}${RESET}`);
      console.log(`${DIM}  ${step.description}${RESET}`);

      if (!autoRunMode) {
        const answer = await rl.question(
          `${DIM}  Press Enter to run, s to skip, q to quit: ${RESET}`,
        );
        const cmd = answer.trim().toLowerCase();
        if (cmd === 'q') {
          console.log('\nQuitting demo.');
          break;
        }
        if (cmd === 's') {
          console.log(`${DIM}  Skipped.${RESET}`);
          results.push({ name: step.name, status: 'skipped' });
          continue;
        }
      } else {
        console.log(`${DIM}  Running (non-interactive)...${RESET}`);
      }

      try {
        await step.run(rl);
        console.log(`${GREEN}  ✓ ${step.name} — step completed${RESET}`);
        results.push({ name: step.name, status: 'passed' });
      } catch (err) {
        if (err instanceof QuitError) {
          console.log('\nQuitting demo.');
          break;
        }
        const msg = err instanceof Error ? err.message : String(err);
        if (err instanceof KnownIssueError) {
          // The step itself classified this failure as a known external issue.
          console.log(`${YELLOW}  ⚠ ${step.name} — known issue (not a failure): ${msg}${RESET}`);
          if (err.detail) console.log(`${DIM}  ${err.detail}${RESET}`);
          results.push({ name: step.name, status: 'known-issue', error: msg });
        } else if (step.knownIssue) {
          console.log(`${YELLOW}  ⚠ Known issue (not a failure): ${msg}${RESET}`);
          console.log(`${DIM}  ${step.knownIssue}${RESET}`);
          results.push({ name: step.name, status: 'known-issue', error: msg });
        } else {
          // No more "this is expected if the replica lacks funds" — a thrown step is a
          // genuine failure and is reported as one.
          console.log(`${RED}  ✗ FAILED: ${msg}${RESET}`);
          results.push({ name: step.name, status: 'failed', error: msg });
        }
      }
    }
  } finally {
    rl.close();
  }

  const summary = summarizeResults(results);
  printSummary(summary);
  // Surface failure to any wrapper / CI: a non-zero exit code when a step failed.
  if (summary.failed > 0) process.exitCode = 1;
  return summary;
}

/**
 * Prompt for confirmation within a step. Returns true to continue, false to skip.
 * Typing 'q' quits the entire demo. In non-interactive (autoRun) mode, always continues.
 */
export async function confirm(rl: readline.Interface, prompt: string): Promise<boolean> {
  if (autoRunMode) return true;
  const answer = await rl.question(`${DIM}  ${prompt} (Enter/s/q): ${RESET}`);
  const cmd = answer.trim().toLowerCase();
  if (cmd === 'q') throw new QuitError();
  return cmd !== 's';
}
