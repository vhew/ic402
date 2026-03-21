import * as readline from 'node:readline/promises';
import { stdin, stdout } from 'node:process';

const DIM = '\x1b[2m';
const RESET = '\x1b[0m';

/** Thrown when the user chooses to quit from any prompt. */
export class QuitError extends Error {
  constructor() {
    super('quit');
  }
}

export interface StepDef {
  name: string;
  description: string;
  run: (rl: readline.Interface) => Promise<void>;
}

/**
 * Run a list of steps interactively.
 * Each step prints its name and description, then waits for the user to
 * press Enter (run), type 's' (skip), or 'q' (quit).
 *
 * A single readline interface is shared across all steps to avoid
 * stdin conflicts from creating/closing multiple interfaces.
 */
export async function runSteps(steps: StepDef[]): Promise<void> {
  const rl = readline.createInterface({ input: stdin, output: stdout });

  try {
    for (let i = 0; i < steps.length; i++) {
      const step = steps[i];
      console.log(
        `\n${DIM}[${i + 1}/${steps.length}]${RESET} \x1b[1m${step.name}\x1b[0m`,
      );
      console.log(`${DIM}  ${step.description}${RESET}`);

      const answer = await rl.question(
        `${DIM}  Press Enter to run, s to skip, q to quit: ${RESET}`,
      );
      const cmd = answer.trim().toLowerCase();

      if (cmd === 'q') {
        console.log('\nQuitting demo.');
        return;
      }
      if (cmd === 's') {
        console.log(`${DIM}  Skipped.${RESET}`);
        continue;
      }

      try {
        await step.run(rl);
      } catch (err) {
        if (err instanceof QuitError) {
          console.log('\nQuitting demo.');
          return;
        }
        const msg = err instanceof Error ? err.message : String(err);
        console.log(`\x1b[31m  Error: ${msg}\x1b[0m`);
        console.log(
          `${DIM}  This is expected if the local replica lacks funded accounts.${RESET}`,
        );
      }
    }
  } finally {
    rl.close();
  }
}

/**
 * Prompt for confirmation within a step (e.g., between sub-actions in the
 * session flow). Uses the shared readline interface.
 * Returns true to continue, false to skip. Typing 'q' quits the entire demo.
 */
export async function confirm(
  rl: readline.Interface,
  prompt: string,
): Promise<boolean> {
  const answer = await rl.question(
    `\x1b[2m  ${prompt} (Enter/s/q): \x1b[0m`,
  );
  const cmd = answer.trim().toLowerCase();
  if (cmd === 'q') throw new QuitError();
  return cmd !== 's';
}
