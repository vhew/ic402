# Releasing ic402

ic402 has **two independent version numbers**. Most releases move only the first.

| Version | What it is | Bumps | How |
|---|---|---|---|
| **Package version** (e.g. `2.2.4`) | the mops/npm release number | **every release** | `scripts/version.sh` |
| **`STABLE_SCHEMA_VERSION`** (e.g. `1`) | the library's stable-state contract (`Ic402.STABLE_SCHEMA_VERSION` in `src/ic402/lib.mo`) | **only when a `Stable*State` type changes incompatibly** | hand-edit `lib.mo` + `check-stable-compat.sh --update` |

## What gets published

- **mops:** `ic402` (source of truth: `mops.toml`; ships `src/ic402/**/*.mo`).
- **npm:** `@ic402/client` (`packages/client`) and `@ic402/mcp` (`integrations/mcp`).
- The root `ic402` and `@ic402/example-client` packages are `private` — they carry the version for
  consistency but are **not** published.

`scripts/version.sh` syncs the version across **9 files** (mops.toml, the four `package.json`s,
`example/zk-verifier/Cargo.toml` + `Cargo.lock`, and the runtime version literals in
`integrations/mcp/src/index.ts` + `example/client/src/index.ts`). It does **not** touch
`CHANGELOG.md` or the "versions uniform at X" line in `docs/production-readiness.md` — those are
edited by hand each release.

---

## A. Standard release (no breaking stable change)

This is almost every release. The `stable-compat` CI job passes on its own, so there's nothing
extra to do for the stable contract.

1. **Land your changes** on `master` and confirm **CI is green** on the commit you're about to tag.
2. **Bump the version:**
   ```bash
   ./scripts/version.sh 2.2.5          # or: patch | minor | major  (also: pnpm version:bump 2.2.5)
   ```
3. **By hand** (what version.sh doesn't touch):
   - `CHANGELOG.md` — prepend a `## v2.2.5 — YYYY-MM-DD` entry (most-recent-first), with a
     release-type summary line + categorized `###` subsections. State whether there are any
     wire/HTTP or `@ic402/client` breaking changes. If an `## Unreleased` section exists, fold it
     into the new entry. The release workflow takes the GitHub Release notes from this entry.
   - `docs/production-readiness.md` — the "versions uniform at X" line.
4. **Commit and push master.** `release.yml` ignores branch pushes, so this publishes nothing:
   ```bash
   git commit -am "release: v2.2.5"
   git push origin master
   ```
5. **Tag and push the tag — this is the publish.** Wait for CI on the release commit to be green
   first; a published version can't be taken back. Annotated tag, `ic402 vX.Y.Z (…)` subject, as
   the existing tags:
   ```bash
   git tag -a v2.2.5 -m "ic402 v2.2.5 (short description)"
   git push origin v2.2.5
   ```
   The tag push runs `.github/workflows/release.yml`, which:
   - refuses a tag that doesn't match `mops.toml`'s version;
   - packs both npm packages and proves they install (`scripts/check-npm-pack.sh`);
   - creates the GitHub Release from the version's CHANGELOG entry;
   - publishes `@ic402/client` and `@ic402/mcp` to npm by **trusted publishing** (GitHub OIDC,
     with provenance) — no npm token on any machine;
   - publishes `ic402` to mops with the `release` environment's `MOPS_IDENTITY_PEM` secret.

   Each publish skips a version its registry already has, so re-running the workflow is safe. The
   one-time setup (npm trusted publishers, the `release` environment) is described in the header of
   `release.yml`.
6. **Verify** once the workflow is green:
   ```bash
   npm view @ic402/client@2.2.5 version     # npm can lag ~a minute after a publish; re-check before
   npm view @ic402/mcp@2.2.5 version        # calling it failed
   ```
   Then run a real `npm install @ic402/mcp@2.2.5` in an empty directory (it proves the published
   dependency ranges resolve), and check that https://mops.one/ic402 lists the version.

> **Old npm versions** can only be deprecated from your machine (`npm login`, then
> `npm deprecate`): CI's trusted publishing can publish, nothing else.

---

## B. Release **with** a breaking stable-state change

A "breaking" change to one of the four library `Stable*State` types is a removed or retyped field,
or a **new field on an existing stable record** (breaking because consumers hold these in mutable
`stable var`s, whose type is invariant across upgrade). Adding a new variant case or a brand-new
`?optional` stable variable is **not** breaking.

You'll know you have one because **CI's `stable-compat` job fails** with
`BREAKING ic402 stable change with NO version bump`. To release it safely:

1. **Bump** `Ic402.STABLE_SCHEMA_VERSION` in `src/ic402/lib.mo` (`1` → `2`).
2. **Provide a migration.** Wire the `#migrate` branch of the `checkSchemaVersion` guard (see the
   pattern in `example/main.mo` and [`docs/upgrade-safety.md`](docs/upgrade-safety.md)), or document
   a state-dropping fresh deploy in the CHANGELOG.
3. **Advance the baseline:**
   ```bash
   ./scripts/check-stable-compat.sh --update     # refuses unless step 1 happened; re-stamps the baseline
   ```
4. **Commit** the bumped `lib.mo` + the new `test/stable-anchor.most` + your migration, then do the
   standard release (A). Call out the `STABLE_SCHEMA_VERSION` change and the migration prominently
   in the CHANGELOG.

> Don't hand-edit `test/stable-anchor.most` — it's generated, and advancing it without a version bump
> defeats the gate (it carries a "do not hand-edit" header). Always use `--update`.

For an **additive** stable change you skip section B entirely: the gate stays green and you don't
bump `STABLE_SCHEMA_VERSION` or advance the baseline. Leaving the baseline at an older signature is
fine — it keeps proving "anyone from that version can still upgrade."

---

## The stable-compat gate (what it's protecting)

`scripts/check-stable-compat.sh` (CI job `stable-compat`) compiles `test/stable-anchor.mo` — a
fixture that persists exactly the four library `Stable*State` types — to a `.most` stable signature
and compares it to the committed baseline with moc's own `--stable-compatible` oracle. It **fails the
build** on a stable change that is upgrade-incompatible *and* doesn't bump `STABLE_SCHEMA_VERSION`,
so a downstream consumer can never silently trap in `loadStable` on a live, fund-holding canister.
A `--self-test` run proves the gate still discriminates. Full design + the consumer-side pattern:
[`docs/upgrade-safety.md`](docs/upgrade-safety.md).

## Pre-release checklist

CI runs all of this on push; to check locally before tagging:

```bash
mops test                                   # Motoko unit suites
pnpm test:client                            # @ic402/client
pnpm exec vitest run                         # MCP guards/security + integration (skips w/o a replica)
pnpm build:client && pnpm build:demo         # type-check + build the published TS
bash scripts/build-example.sh /tmp/ex.wasm   # B0: example stays installable (wasm locals budget)
./scripts/check-stable-compat.sh             # stable contract gate
./scripts/check-stable-compat.sh --self-test # gate self-test
bash scripts/gen-did.sh && git diff --exit-code example/example.did   # Candid in sync
pnpm format:check && pnpm lint
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the dev setup and [`docs/upgrade-safety.md`](docs/upgrade-safety.md)
for how consumers handle an ic402 bump.
