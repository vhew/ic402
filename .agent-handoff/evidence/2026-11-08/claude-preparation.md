# Claude preparation evidence — 2026-11-08 21:15–21:16 UTC

- [verified] Main checkout clean on master at `3af30b40ec7875a3bd734fb83756ec06c22d3aeb`,
  equal to origin/master after fetch. Records branch clean at `bb3e4224abce6e56f844105e4c68e12ff516b1cb`;
  `git rev-list --left-right --count origin/chore/agent-handoff...chore/agent-handoff` returned 0 / 4.
  Origin records tip is `81318a0b0db02d4e674de3e260146a1f1a4bd49d`; no divergence or push.
- [verified] Helper files are byte-identical to tested `ccef51a`:
  `git diff --exit-code ccef51a HEAD -- .agent-handoff/doctor.py .agent-handoff/doctor_probes.py
  .agent-handoff/handoff.sh .agent-handoff/probe-doctor.sh` returned 0. Existing complete Bash/Zsh
  probe logs (44 broken-input probes / 29 IDs) remain applicable; no probe rerun was needed here.
- [verified] Fresh command from the main implementation checkout:
  `bash <records>/.agent-handoff/handoff.sh doctor --repo <implementation> --level tools --json`.
  Exit 1, NOT READY, 1.38 seconds; details are in `claude-preparation-doctor.json` (sanitized).
  All pinned version/dependency/cache checks pass; foreign tool PATH selection fails.
- [verified] The same helper launched from the records worktree reports a different PATH failure:
  icp does not match the repository pin, mops is missing, and the PATH check fails. Both runs
  are NOT READY. This confirms that shell/worktree context matters; no environment was repaired.
- [verified] A read-only `ps -axo pid=,comm=` inventory, filtered to relevant executable basenames,
  found 15 PocketIC processes. No command arguments or private paths were retained in this record.
  [open] Their task ownership is unknown; they were not stopped or otherwise changed. Local PIDs
  belong in the ignored checkpoint, not this public record.
- [verified] `git stash list` shows one existing voucher-hardening stash; preserved untouched.
- [open] This is not a release handoff and no product gate was run. The earlier release-readiness
  result in VALIDATION.md still has CI-only credential usability unverified; do not reuse it as
  proof that publication can succeed now.
