# Handoff lessons validation — 2026-11-08

- [verified] Implementation examined: `3af30b40ec7875a3bd734fb83756ec06c22d3aeb` (master).
- [verified] Helper/protocol implementation tested: `ccef51a0eae92e6e26c5ccfaf99fa3aa3085dd9d`.
  Later evidence/record commits do not alter the helper. These commits are local, not published.
- [verified] Existing instruction lines were checked in order against `81318a0`: none deleted
  from PROTOCOL.md, BOOTSTRAP.md, AGENTS.md or CLAUDE.md. Dated additions supply corrections.
- [verified] Source excerpts were committed before their use: `999aeb3`; its overbroad paraphrase
  about accessing secrets has an explicit adjacent correction in the implementation commit.

## Inventory found before implementation

| Classification | Artifact | Location / result |
|---|---|---|
| verified | Procedure | records branch `.agent-handoff/PROTOCOL.md` |
| verified | Current/history | records branch `.agent-handoff/CURRENT.md`, `HISTORY.md` |
| verified | New-machine guide | records branch `.agent-handoff/BOOTSTRAP.md` |
| verified | Existing helper | none in tracked records/scripts tree; created handoff.sh doctor |
| verified | Local checkpoint | implementation checkout `.agent-handoff/LOCAL.md`, ignored via local Git exclude |
| verified | Main checkout | master remained at the implementation SHA; handoff changes use a separate worktree |

## Commands and results

| Classification | Command / source | Actual result / evidence |
|---|---|---|
| verified | `bash .agent-handoff/probe-doctor.sh` | exit 0; [complete log](evidence/2026-11-08/bash-probes.log) |
| verified | `zsh .agent-handoff/probe-doctor.sh` | exit 0; [complete log](evidence/2026-11-08/zsh-probes.log) |
| verified | Both probe runs | 44 broken inputs cover 29 check IDs; passing fixture levels tools/integration/deploy; release runtime intentionally uncheckable |
| verified | Additional controls | PNPM_HOME exception, wrong-tool API suppression, Corepack no-download/no-auto-pin, real timeout, missing/old Python, both shell entrypoints |
| verified | `handoff.sh doctor --repo <code> --level <level> --json` | all four levels exit 1; [sanitized statuses/timings](evidence/2026-11-08/machine-results.json) |
| verified | Real tools run | pins/dependencies/caches pass; inherited foreign tool PATH fails; no repair applied |
| verified | Real integration run | prerequisite failures stop identity/API probes; no integration readiness claim |
| verified | Real deploy run | missing authoritative profile plus PATH failure; no planning/deployment attempted |
| verified | Real release run outside network sandbox | real GitHub login/repository permissions and secret-existence API checks pass; CI credential usability remains uncheckable |
| verified | `git diff --check` and staged equivalent | passed before implementation commit |

- [verified] Real runs took approximately 1.5–2.9 seconds each. No production deployment,
  publishing, key export or dependency installation was performed. No application code changed.
- [open] There is no real fully configured-machine passing control yet: the primary agent shell
  resolves icp/mops through a foreign project bin directory. Synthetic controls do not substitute
  for that acceptance evidence. Recommendation: install/select repo-pinned tools in this shell,
  rerun tools/integration, and retain a real green control before relying on the readiness gate.
- [open] Production profile/guard integration remains blocked: no authoritative deployed example
  principal in tracked config, and private deploy tooling remains unread/unmodified. Recommend
  recording the public target then guarding the actual entrypoint; doing less leaves it blocked.
- [open] A local machine cannot verify the CI-only OIDC exchange or mops secret usability. The
  release-runtime check intentionally cannot pass locally; its negative probe establishes that
  unavailable evidence never becomes OK. No live publishing control was run or authorized.

## Fresh-reader check

- [verified] Independent reader `inspect_deploy` checked source claims, owner quotations, additive
  preservation, and the helper. It reproduced and checked fixes for missing Motoko sources,
  Corepack bootstrap, implicit signing booleans, minter subaccounts and the PNPM_HOME exception.
- [verified] That reader reran the frozen 44-probe suite through Bash, exit 0, and found no further
  concrete blocker. The primary agent then ran both full shell suites at the helper commit above.
- [verified] Paths, commit identities, template size and the absence of product changes were
  command-checked. This is a validation summary, not a separately requested review packet.
- [open] New local material is not on origin. Before any eventual record publication, recheck
  reachability and all record claims at that point; this task's no-push instruction remains active.

## Scope and choices

- [approved] Omitted multi-repository WIP refs, paired commits and cross-repository scans; this
  is one repository with existing code/records separation. Source: owner request R7.
- [verified] No browser runner or TTY-only gate logger was found. Doctor reports browser N/A;
  protocol §11 proposes an always-written gate summary only as future work, without changing gates.
- [assumed] Python 3.11+ standard library and an explicit committed JSON deploy profile were
  implementation choices. Rationale/undo: avoid installing parser dependencies and avoid guessing
  live IDs; replace helper runtime/profile adapter if an approved existing format becomes available.
- [verified] No release is underway and no full product gate was rerun for these handoff changes.
  A future pre-release handoff without its own exact-commit green phases must say gate owed first.
