# Doctor and migration checks — 2026-11-08

- [approved] Scope: read-only readiness requested in `authorities/2026-11-08-owner-request.md` R7.
  All handoff tooling lives on the records branch. Pass `--repo` for the actual code checkout;
  the records branch's product snapshot is not a substitute. Nothing here authorizes deployment,
  publishing, funding, key export, or changes to live services.
- [assumed] Implementation choice: a small Bash/Zsh-compatible dispatcher plus Python 3.11+
  (standard-library TOML support). Python is an explicit helper prerequisite, not a new product
  toolchain pin. No package-manager bootstrap or auto-install is performed.

## Usage

[verified] The helper's interface is:

```sh
bash <records-worktree>/.agent-handoff/handoff.sh doctor --repo <code-worktree> --level tools
bash <records-worktree>/.agent-handoff/handoff.sh doctor --repo <code-worktree> --level integration
bash <records-worktree>/.agent-handoff/handoff.sh doctor --repo <code-worktree> --level deploy --profile <recorded-target.json>
bash <records-worktree>/.agent-handoff/handoff.sh doctor --repo <code-worktree> --level release
bash <records-worktree>/.agent-handoff/probe-doctor.sh
zsh <records-worktree>/.agent-handoff/probe-doctor.sh
```

- [verified] `--json` selects machine-readable diagnostics. Nonzero means NOT READY; failures
  include a suggested fix. N/A is a distinct, source-backed applicability result, not a pass for
  unavailable input. Subprocess stdin is closed; output that could contain secrets is suppressed.
- [assumed] A 55-second overall subprocess budget and individual timeouts bound typical runs to
  about a minute. File checks also run locally; this is a readiness check, not a full gate.
- [approved] Keep raw machine reports local: tool paths may be machine-specific. Publish only
  sanitized findings, command/commit identifiers, counts and results. Doctor itself does not
  write logs; capture its output deliberately into ignored/local storage if evidence is needed.

## Chosen checks and their sources

| Classification | Check / level | Source and reason |
|---|---|---|
| verified | Repo pin parsing and consistency / all | package.json, mops.toml, CI/release YAML; fail on unsupported schema or disagreeing pins |
| verified | Node, pnpm, icp, mops and first PATH binary / all | package.json engine/packageManager/devDependency, CI mops/icp installs; CI documents an unpinned icp upgrade failure |
| verified | Foreign PATH shadowing / all | scripts/lib/toolchain-path.sh and setup.sh document another project's CLI taking precedence |
| verified | Installed workspace dependencies/lock / all | pnpm-workspace.yaml, manifests, pnpm-lock.yaml and installed lock snapshot; detect missing/stale installs |
| verified | Motoko dependency cache / all | mops.toml + mops.lock; setup.sh documents an empty .mops after failed install |
| verified | moc/wasmtime downloaded executables / all | mops.toml toolchain; do not invoke a resolver that downloads missing binaries |
| verified | Binaryen and didc caches / all | fetch-binaryen.sh and check-candid-mirrors.sh pins/platform mappings; required by CI build/interface checks |
| verified | Prebuilt ledger/RPC artifacts / all | scripts/prebuilt.sha256; setup verifies cached bytes before deploying local fixtures |
| verified | Browser applicability / all | workspace manifests and CI contain no browser runner; optional Vitest peer strings do not require Playwright |
| verified | Environment files / all | present optional .env.development/.env.production, plus profile-required files; owner-only permissions, parse as data, never source |
| verified | Exported payer identity / integration | .local/test-payer.pem vs CLI test-payer principal; CI documents anonymous fallback when export is missing |
| verified | Local mappings, controller access, minter, funding / integration | icp.yaml, test/helpers.ts and predemo.sh; compare actual principals and decoded API results, not CLI exit alone |
| verified | Existing deployment target/link/identity/status / deploy | Explicit committed target profile required; icp.yaml alone has no deployed example ID |
| verified | Working GitHub login/permissions / release | Real authenticated GitHub user/repo API calls; auth status display is insufficient |
| verified | Release workflow/environment checks / release | release.yml uses npm OIDC and MOPS_IDENTITY_PEM; no local npm token login is invented |
| approved | CI-only publishing auth / release | Unknown secret usability/OIDC cannot be labeled OK; remain blocked until checked in an authorized context |
| verified | Signing applicability / release | Git signing configuration checked without signing; existing release docs require annotated, not necessarily signed, tags |

- [verified] `scripts/setup.sh` and `scripts/predemo.sh` change fixture state and are never run by
  doctor. They may appear as fixes for the owner to execute deliberately. Doctor does not repair
  PATH, chmod files, create identities, fund accounts, install dependencies or alter mappings.
- [open] Version checks on extracted Binaryen/didc executables do not establish archive integrity
  when the verified source archive is no longer retained. Prebuilt artifacts have retained hashes;
  do not describe all cache checks as checksum verification. Restore from pinned verified downloads
  if the trust of an extracted executable is in question.

## Deploy target contract and boundary

- [assumed] Use an explicit public-safe committed JSON record in the implementation checkout,
  outside `deploy/`; require it to match HEAD. Its authority must be reviewed, not inferred from
  a nonempty string. Do not create a fictitious target or copy an external ledger ID as this
  project's canister ID. Expected format (placeholders are deliberately not runnable):

```json
{
  "environment": "ic",
  "identity": "OWNER_APPROVED_LOCAL_IDENTITY_LABEL",
  "principal": "EXPECTED_PUBLIC_DEPLOYER_PRINCIPAL",
  "canisters": { "example": "RECORDED_EXISTING_CANISTER_PRINCIPAL" },
  "authority": "COMMITTED_RULING_PATH_AND_DATE",
  "env_files": [".env.production"]
}
```

- [verified] `env_files` is optional; no env file is required merely because a template exists.
  Any present env file still receives permission/syntax checks. No secret belongs in the profile.
- [open] No authoritative mainnet target record was found in tracked files at code commit
  `3af30b40ec7875a3bd734fb83756ec06c22d3aeb`. The current deploy level therefore fails closed.
- [verified] Installed pinned CLI help provides `icp deploy --no-create` and
  `icp canister status <name> -e <env> --id-only`. [assumed] Recommend an existing-deploy guard
  that first matches the local mapping to the committed target, then deploys with `--no-create`.
- [open] There is no tracked production deploy entrypoint to patch. Private `deploy/` remains
  unread and unmodified. A wrapper alone cannot protect scripts that bypass it. Owner choice:
  provide the authoritative target and approve integrating the guard, or do less and leave
  production deployment blocked. Recommendation: record the public target first, then guard the
  actual entrypoint in a clean product branch; never merge handoff history into it.

## Evidence, probes and limits

- [approved] Probes must exercise each readiness check with a passing fixture and broken input,
  including command failures/timeouts, changed pins, missing caches/dependencies, wrong identities,
  unsafe env permissions and missing mappings. Run through both Bash and Zsh. Synthetic fixtures
  prove discrimination; they do not prove the real machine is configured or credentials work.
- [approved] Record a real run separately. Missing tools or network access produce failures with
  fixes, not fabricated passing controls. Do not install or alter the user's environment just to
  turn the diagnostic green. If no real ready machine is available, keep that control open.
- [approved] Prompted signing, encrypted-key access and confirmations belong in the owner's
  terminal. Check preconditions and public results afterward; never put passphrases in arguments.
- [approved] See the final validation evidence for actual runs and unresolved checks; an earlier
  library test run is not evidence for this new helper. No release is being prepared by this task.

- [verified] The prebuilt check also reads the ZK artifact path from `icp.yaml` and verifies its
  gzip stream starts with the Wasm header. This is a presence/format check, not a claimed source
  rebuild or checksum verification. Actual results are in `VALIDATION.md`.
