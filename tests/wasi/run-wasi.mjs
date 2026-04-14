// Smoke test: run minipandoc.wasm via Node's WASI, passing arguments,
// piping stdin (or a fixture file) as input. Emits the converted output
// on the host stdout.
//
// Usage:
//   node run-wasi.mjs <args...>
// Example:
//   node run-wasi.mjs -f djot -t html tests/fixtures/djot/basic.dj
import { WASI } from "node:wasi";
import { argv, env, stdout, stderr, exit } from "node:process";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
// Walk up from tests/wasi/ to the project root.
const projectRoot = resolve(here, "..", "..");
const wasmPath = resolve(
  projectRoot,
  "target/wasm32-wasip1/release/minipandoc.wasm",
);
const userArgs = argv.slice(2);

const wasi = new WASI({
  version: "preview1",
  args: ["minipandoc", ...userArgs],
  env,
  // Preopen the project root so fixture paths like
  // "tests/fixtures/djot/basic.dj" resolve. Map the host path to itself
  // so absolute paths passed on argv work unchanged.
  preopens: { [projectRoot]: projectRoot },
  returnOnExit: true,
});

const wasmBuffer = await readFile(wasmPath);
const wasmModule = await WebAssembly.compile(wasmBuffer);
// wasi-sdk 25's wasi-libc imports `env.__wasi_init_tp` (thread-pointer
// init) which isn't part of wasi_snapshot_preview1 and which Node's WASI
// shim doesn't supply. We have no threads, so a no-op stub is safe.
const imports = {
  ...wasi.getImportObject(),
  env: {
    __wasi_init_tp: () => {},
  },
};
const instance = await WebAssembly.instantiate(wasmModule, imports);
const code = wasi.start(instance);
exit(code ?? 0);
