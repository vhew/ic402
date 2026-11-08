# Handoff record template — 2026-11-08

[approved] Copy for the next formal handoff; target about 150 lines, with detail in committed
citations. Replace placeholders with evidence. Every substantive entry must say verified,
approved, assumed, or open. Keep the historical record untouched until a new handoff is prepared.

## 1. Read this first

- [open] ID / UTC / from / to: <HO-ID / time / agent / agent>.
- [open] Objective: <one line>.
- [open] Authorized: <scope and committed owner-ruling citation>.
- [open] Not authorized: <scope boundary; pushes/tags/deploys as applicable>.
- [open] Task type: <product | metadata only>; implementation branch / full SHA: <...>.
- [open] Records branch: chore/agent-handoff; on origin: <verified refs or not synchronized>.
- [approved] Read STANDING.md and latest PROTOCOL.md first; preserve their branch separation.

## 2. Task ledger

[approved] Each row has its own authority and preservation boundary. “Build” means ruled scope,
not permission to skip the receiver's confirmation. “Held” requires an actual owner hold citation.
“Done” requires acceptance evidence; do not confuse code evidence with required issue delivery.

| ID | What (one line) | Authority (ruling, date, committed source) | Read design first | Must not change | Mode | Acceptance | Status / evidence |
|---|---|---|---|---|---|---|---|
| <id> | [open] <what> | [open] <ruling or missing> | <committed paths + headings> | <contract/invariant> | <build / ask-first / held / done> | <observable criteria> | [open] <state; exact evidence> |

## 3. Decisions I made without a ruling

- [open] <What; why; how to undo it; impact; question + recommendation if product-meaningful>.
- [approved] Write “None” explicitly if none; raise any entries in the next owner message too.

## 4. Verified state

| Claim / classification | Command or source at recorded SHA | Result / exit | Durable log / evidence |
|---|---|---|---|
| [open] <claim> | <command> | <actual result> | <committed sanitized evidence> |

- [open] Fresh-reader fact check: <reader, date, exact claims checked, discrepancies/corrections>.
- [open] Citation audit: <every path tracked and on origin; explicitly lost/open material>.
- [open] Reproducibility: <code SHA; helper SHA; dirty state; evidence cannot describe itself>.

## 5. Open questions

| ID / classification | Real choice / options (include doing less) | My recommendation / reason | Owner answer / source |
|---|---|---|---|
| Q1 [open] | <A / B / defer-do-less> | <recommendation> | <pending or dated ruling> |

## 6. Next actions

1. [open] <“gate owed” first if a pre-release phase lacks one green run at the recorded commit>.
2. [approved] Receiver restates ledger, doctor, mismatches, preserved design and needed choices;
   owner confirms/corrects once before building or committing. Read-only work can continue.
3. [open] <next bounded action with task ID>.

## 7. Machine prerequisites

- [open] Doctor: <level, UTC, shell, repo/helper SHAs, command, exit, verdict, sanitized log>.
- [open] Old-machine doctor / transfer manifest: <public-safe asset labels, fingerprints,
  permissions, owner-held transfer location; no secrets or private paths>.
- [open] New-machine doctor: <result before gates/deploy; any uncheckable check is a blocker>.
- [open] Owner-terminal actions: <prompting signing/key/auth command; pre/post verification>.

## 8. Repo state and tests actually run

- [open] Branches / full SHAs / remote verification / ahead-behind / dirty files / stashes: <...>.
- [open] Tests: <exact command, code SHA, exit, complete log; skipped/not run named explicitly>.
- [open] Release phases: <one green run per phase at recorded commit or gate owed>.
- [approved] Never assemble several partial logs into a claim of one green run.

## 9. Unsafe states

| Classification | Process/service | Owner (agent/user) | PID or safe identifier | Purpose / state | Safe next action |
|---|---|---|---|---|---|
| [open] | <running process or None after check> | <who owns it> | <identifier> | <in flight?> | <observe; do not kill unknown work> |

- [approved] Never include credentials, PEMs, token-bearing commands, private account names,
  or machine-specific paths in a public record. Cite safe durable summaries.
