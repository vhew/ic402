# Claude handoff — prepared locally, not synchronized

> [approved] **2026-11-08 publication correction:** the owner explicitly approved the push;
> source `authorities/2026-11-08-claude-handoff.md` at `8d64cf2` (already on origin).
> [verified] Implementation `383b7fe` and handoff `efc63c1` are now on origin/chore/agent-handoff.
> The title and pending-push statements below describe preparation and are superseded for this
> handoff. Q1 is resolved; Claude can now use “Resume from Codex” after fetching and reading the
> latest branch-tip corrections. H3/H4 and the NOT READY doctor verdict remain open.
> [approved] This approval is limited to this handoff; STANDING.md S6 still governs other pushes.
>
> [approved] **2026-11-18 resume confirmation:** Claude resumed this handoff on 2026-11-09 and the
> owner confirmed its restatement and all nine recommendations with “1 confirmed.” (`authorities/2026-11-18-resume-confirmation.md`).
> It supersedes the open rows and questions below:
> - H1 done. H2 done; the doctor is frozen and advisory (PROTOCOL §9 addition). H3 deferred until a
>   product task needs `mops test`, then the shell is fixed with the owner's OK. H4 held: no mainnet
>   deploy is planned. H5 done: published 2026-11-08.
> - Q1 resolved (pushed). Q2 resolved as H3. Q3 resolved as H4. [open] Q4: should `master` get a
>   product-only `AGENTS.md`, so Codex sessions in the main checkout get the project instructions?
>   Unanswered.
> - Push authority: PROTOCOL §2's rule again (`STANDING.md` S6 correction 2); the lapsed
>   update-scoped lines are listed in one PROTOCOL §2 correction.
> - [verified] The PocketIC processes in §9 belong to a sibling project's local network (read-only
>   check, 2026-11-09). They are not ic402's to stop.
> - [approved] The handoff-system work is closed. Product work continues through proposals: PR #51
>   (viem colon-name interop, scoped `setup.sh` cleanup, `RELEASING.md`) and a ledger-deduplication
>   design the owner asked to have done by Fable (“3 design fix use fable.”).
>
> [verified] **2026-11-18 H3 control:** with the owner's OK (“ok for the two checks.”), Claude's
> shell now selects `mops` 3.5.1 from the `ic402` conda environment and the project's own `icp` 1.7.0
> ahead of the Homebrew copy. `handoff.sh doctor --level tools` against master 3af30b4: READY, exit 0
> (every check PASS except `browsers` and `env`, both N/A). That is the first real configured-machine
> control for H3 at the tools level; integration level not yet run.

## 1. Read this first

- [verified] ID: HO-20261108T2116Z-codex; UTC: 2026-11-08 21:16; codex -> claude.
- [approved] Objective: transfer the existing handoff-tooling work; no product feature is authorized.
- [approved] Authority: `authorities/2026-11-08-claude-handoff.md`; read STANDING.md first.
- [open] Push approval remains pending. No remote-ready claim; master, tags and deploys stay untouched.
- [verified] Task type: metadata only; implementation and records branch: chore/agent-handoff.
- [verified] Implementation: `383b7fec6cc10e40333297f505371598b85f270c`; on origin: no, at preparation.
- [verified] Product baseline: master `3af30b40ec7875a3bd734fb83756ec06c22d3aeb`; already on origin.
- [approved] Use the current local protocol/corrections while unpublished; do not discard newer local work.

## 2. Task ledger

| ID | What | Authority (date/source) | Design first | Must not change | Mode | Acceptance | Status / evidence |
|---|---|---|---|---|---|---|---|
| H1 | [approved] Add handoff lessons/template/standing rules | 2026-11-08 request R2/R7 in authorities/2026-11-08-owner-request.md | PROTOCOL.md; STANDING.md; TEMPLATE.md | Existing rules and product/records separation | done | Additive dated corrections; sourced claims | [verified] ccef51a; preservation evidence in VALIDATION.md |
| H2 | [approved] Read-only doctor and failure probes | Same request R7 | DOCTOR.md; doctor.py; doctor_probes.py | No installs, secrets output, deployment or false OK | done | Per-check broken inputs; shell controls | [verified] 44 probes/29 IDs in Bash+Zsh; live green control separately H3 |
| H3 | [open] Real configured-machine readiness control | Same request R7 | DOCTOR.md; VALIDATION.md; fresh evidence below | No silent environment repair; no fixture result presented as live | ask-first | tools/integration pass in receiving agent shell | [open] Tool/PATH prerequisites fail; no real green control yet |
| H4 | [open] Guard the actual production deploy entrypoint | Same request R7 | DOCTOR.md deployment boundary; icp.yaml on product branch | No guessed IDs, duplicate creation or private deploy/ access | ask-first | Match authoritative ID before plan; --no-create | [open] Public target/controller and approved integration path missing |
| H5 | [approved] Prepare Claude handoff | 2026-11-08 authorities/2026-11-08-claude-handoff.md | PROTOCOL.md §3; STANDING.md S6 | No push inferred from preparation | ask-first | Reviewed local record; remote verification only after approval | [open] Local preparation complete when committed; push pending |

## 3. Decisions I made without a ruling

- [assumed] Python 3.11+ standard-library helper avoids installing parser dependencies. Undo by
  replacing the dispatcher/runtime while keeping behavior and probes; rationale in DOCTOR.md.
- [assumed] An explicit committed JSON deploy profile avoids guessing live targets. Undo by
  adapting to another owner-approved authoritative format. No real profile was invented.
- [assumed] “prepare to move to claude” permits local preparation but does not lift the earlier
  explicit no-push limit. Undo that interpretation with an explicit owner push instruction.
- [verified] The two implementation choices were surfaced to the owner in the previous report;
  the local-only preparation interpretation was surfaced in this turn. No other new design choice.

## 4. Verified state

| Classification / claim | Command or committed source | Result / evidence |
|---|---|---|
| [verified] Product unchanged | git rev-parse master origin/master; git status --short --branch | Both 3af30b4; main checkout clean |
| [verified] No divergence at inspection | git rev-list --left-right --count origin/chore/agent-handoff...chore/agent-handoff | 0 / 4 before preparation commits; origin still 81318a0 |
| [verified] Helper unchanged since testing | git diff --exit-code ccef51a HEAD -- four helper files | Exit 0; see evidence/2026-11-08/claude-preparation.md |
| [verified] Prior validation | VALIDATION.md; evidence/2026-11-08/bash-probes.log and zsh-probes.log | 44 broken-input probes / 29 IDs, both exit 0 at ccef51a |
| [verified] Fresh tools doctor | bash <records>/.agent-handoff/handoff.sh doctor --repo <code> --level tools --json | Exit 1, NOT READY; evidence/2026-11-08/claude-preparation-doctor.json |

- [verified] Rationale, template, standing instructions and evidence were committed before this
  record cites them. Preparation source/evidence: implementation commit 383b7fe; earlier evidence:
  28c0cd9; helper: ccef51a. They are local; remote citation reachability remains unverified/pending.
- [verified] Fresh reader claude_handoff_review checked this record on 2026-11-08: refs, citations,
  counts, logs, privacy and scope passed. Parent command-backed checks also passed; no blocker found.
  [open] Origin synchronization remains pending; reverify remote reachability after any approved push.
- [open] Some older working agreements lack original verbatim owner-source quotations; STANDING.md
  identifies that provenance gap. Preserve the agreements; do not invent their missing rationale.

## 5. Open questions

| ID / classification | Options, including doing less | My recommendation / reason | Owner answer |
|---|---|---|---|
| Q1 [open] | Push records branch, or retain same-machine-only preparation | Push only on explicit instruction, then verify origin; preserves no-push constraint | Pending |
| Q2 [open] | Select/install pinned tools in receiving shell, or leave readiness blocked | Fix shell/tool selection and obtain real green tools/integration controls before product gates | Pending |
| Q3 [open] | Supply public production target/controller and approved guard integration, or keep production blocked | Establish authoritative target first, then guard actual entrypoint with --no-create | Pending |

## 6. Next actions

1. [open] Ask for explicit records-branch push approval; after approval push/fetch/verify both
   implementation and record reachability. Without it, this preparation is local-only.
2. [approved] Claude reads this record and STANDING.md, runs doctor in its own shell, restates
   ID/mismatches, each ledger row, preserved design and decisions with recommendations, then
   waits for one owner confirmation before building/committing. Read-only work may continue.
3. [approved] After successful remote publication, the resume command is “Resume from Codex”.
   Before publication, remote discovery cannot find this handoff: on this machine explicitly read
   the local chore/agent-handoff branch and protocol (git show or its existing records worktree).
4. [open] Resolve H3/H4 only within the confirmed scope. No release is underway; if one is later
   requested without exact-commit green phase evidence, “gate owed” becomes next action 1.
5. [open] Historical, unauthorized product candidates remain in `git show bb3e422:.agent-handoff/CURRENT.md`:
   pending ICP charge recovery/dedup, session-open reject residual, stale manual-release instructions,
   and PR #49 (status not rechecked). Read product CHANGELOG.md/RELEASING.md before proposing work.

## 7. Machine prerequisites

- [verified] Fresh outgoing tools doctor: primary agent shell, Bash dispatcher, product 3af30b4,
  helper files identical to ccef51a; 2026-11-08, exit 1, NOT READY, 1.38 seconds from main checkout.
- [verified] Main-checkout launch selects foreign-project icp/mops binaries; the records-worktree
  launch instead finds a mismatched icp and no mops. Both are blocked. Do not reuse either shell's
  assumptions in Claude; recheck its actual PATH. No environment fix/install was performed.
- [open] No machine migration was explicitly requested. If moving machines too, owner-held keys,
  needed env files, local service links and credential logins need the §9 transfer manifest first;
  none was exported or validated for transfer. Private deploy/ remains unread.
- [open] Production deployed target/controller not recorded. CI-only OIDC/secret usability remains
  uncheckable locally. Prompting login/key/signing steps belong in the owner's terminal; verify
  public preconditions/results afterward. Do not publish to test authentication.

## 8. Repo state and tests actually run

- [verified] Main worktree remains master at the product baseline above. Metadata implementation
  is on chore/agent-handoff; it had four unpushed commits before this preparation, then a source/
  preflight commit. No tracked changes remained before drafting this CURRENT/HISTORY pair.
- [verified] One pre-existing voucher-hardening stash is preserved; do not drop or apply it.
- [verified] This turn ran a fresh doctor and command-backed Git/citation checks, not new helper
  probes or product gates. Prior full Bash/Zsh logs are committed and helper files are unchanged.
- [open] No full product/release gate was run for these metadata changes; no release is authorized.

## 9. Unsafe states

| Classification | Process/service | Owner | Safe identifier | State | Safe next action |
|---|---|---|---|---|---|
| [verified] | Existing PocketIC instances | [open] Not established | 15 executable-name matches; local PIDs in ignored checkpoint | Observed by read-only ps inventory; no ownership claim | Do not stop/restart until ownership is established |
| [verified] | This preparation's tasks | codex | Git/docs/doctor inspection | No persistent service started; doctor completed | No cleanup needed |

- [approved] Keep local paths, PIDs, credentials and private identity material out of published
  records. The LOCAL checkpoint is machine-only; this public record cites sanitized evidence.
