# Summary

<!-- What changes, and why. One concern per PR. -->

## Linked issue

<!-- e.g. Closes #123 -->

## Test plan

<!-- How you verified this. Delete rows that do not apply; add the ones you ran. -->

- [ ] `mops test` — Motoko unit suites
- [ ] `pnpm test:client` — @ic402/client
- [ ] `pnpm exec vitest run` — MCP guards/security + integration
- [ ] `pnpm lint && pnpm format:check`
- [ ] Verified against a local replica (`pnpm setup:local`)

<!-- If you changed behavior, say which test pins it. A fix without a test that
     fails when the fix is reverted is not covered. -->

## Checklist

- [ ] Public Motoko API changed → `packages/client/src/types.ts` updated to match
- [ ] Example canister's Candid interface changed → ran `bash scripts/gen-did.sh` and committed `example/example.did`
- [ ] Stable state changed → `STABLE_SCHEMA_VERSION` bumped and a migration provided (see [RELEASING.md](../RELEASING.md))
- [ ] No change to any of the above

## Notes for reviewers

<!-- Anything non-obvious: tradeoffs taken, things deliberately left out,
     areas where you want a closer look. -->
