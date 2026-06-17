#!/usr/bin/env node
/* eslint-disable */
// check-wasm-locals.js <wasm> [budget=1900]
//
// Fails (exit 1) if any function in the module declares more locals than `budget`.
// The IC rejects a canister install (IC0505) when a function exceeds 2000 locals; we
// keep headroom. Fully-unrolled crypto (mo:sha2 SHA-256, mo:sha3 Keccak) is the usual
// offender — a `wasm-opt -O` build step coalesces it far under the cap. See
// docs/motoko-wasm-locals-review-prompt.md and scripts/build-example.sh.
const fs = require('fs');
const file = process.argv[2];
const budget = Number(process.argv[3] || 1900);
if (!file) {
  console.error('usage: check-wasm-locals.js <wasm> [budget]');
  process.exit(2);
}
const w = fs.readFileSync(file);
let p = 8; // skip magic (4) + version (4)
let max = 0,
  maxFn = -1,
  fn = 0;
function leb() {
  let r = 0,
    s = 0,
    b;
  do {
    b = w[p++];
    r += (b & 0x7f) * 2 ** s;
    s += 7;
  } while (b & 0x80);
  return r;
}
while (p < w.length) {
  const id = w[p++];
  const size = leb();
  const end = p + size;
  if (id === 10) {
    // Code section: vec(func body); each body = size, vec(local-decl), code
    const n = leb();
    for (let i = 0; i < n; i++) {
      const bodySize = leb(); // read size first — `p + leb()` would use the pre-advance p
      const bodyEnd = p + bodySize;
      const decls = leb();
      let locals = 0;
      for (let d = 0; d < decls; d++) {
        const cnt = leb();
        p++; // valtype byte
        locals += cnt;
      }
      if (locals > max) {
        max = locals;
        maxFn = fn;
      }
      p = bodyEnd;
      fn++;
    }
  }
  p = end;
}
const fail = max > budget;
console.log(
  `${file}: max per-function locals = ${max} (code fn #${maxFn}); budget ${budget} -> ${fail ? 'FAIL' : 'ok'}`,
);
if (fail) {
  console.error(
    `ERROR: a function has ${max} locals (> ${budget}). The IC rejects install at >2000 ` +
      `(IC0505). Ensure the build runs wasm-opt -O (see scripts/build-example.sh).`,
  );
}
process.exit(fail ? 1 : 0);
