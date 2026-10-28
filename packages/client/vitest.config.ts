import { defineConfig } from 'vitest/config';

// vitest 5 no longer reads a config from parent directories, so the client suite keeps the
// repo's settings here explicitly (the root vitest.config.ts covers test/ at the repo root).
export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    testTimeout: 120_000,
  },
});
