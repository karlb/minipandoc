// Browser entry point for minipandoc. Loads the WASI-compiled binary under
// @bjorn3/browser_wasi_shim, provides an in-memory filesystem containing the
// input, captures stdout, and returns the converted document.
//
// Mirrors the Node harness at tests/wasi/run-wasi.mjs — same argv shape, same
// __wasi_init_tp no-op stub. The only difference is the WASI implementation:
// node:wasi there, browser_wasi_shim here.

import {
  WASI,
  File,
  OpenFile,
  PreopenDirectory,
  ConsoleStdout,
} from "../scripts/vendor/browser_wasi_shim/index.js";

const WASM_URL = new URL(
  "../target/wasm32-wasip1/release/minipandoc.wasm",
  import.meta.url,
);

let modulePromise;

function loadModule() {
  if (!modulePromise) {
    modulePromise = (async () => {
      const resp = await fetch(WASM_URL);
      if (!resp.ok) {
        throw new Error(
          `failed to fetch ${WASM_URL}: ${resp.status} ${resp.statusText}`,
        );
      }
      // compileStreaming when available (modern Chromium/Firefox); fall back to
      // arrayBuffer + compile on older Safari.
      if (typeof WebAssembly.compileStreaming === "function") {
        try {
          return await WebAssembly.compileStreaming(resp);
        } catch {
          // fall through — some servers return wasm with the wrong MIME type.
        }
      }
      return WebAssembly.compile(await resp.arrayBuffer());
    })();
  }
  return modulePromise;
}

/**
 * Convert `input` from `from` format to `to` format.
 *
 * @param {string} input      - source document text
 * @param {string} from       - input format (e.g. "djot", "native")
 * @param {string} to         - output format (e.g. "html", "markdown", "latex")
 * @param {object} [options]
 * @param {boolean} [options.standalone=false] - pass -s for full document output
 * @returns {Promise<string>} converted document
 */
export async function convert(input, from, to, { standalone = false } = {}) {
  const wasmModule = await loadModule();

  const inputBytes = new TextEncoder().encode(input);
  // Preopen a directory "/input" containing the single file "doc", mirroring
  // how the Node harness preopens the project root. The CLI then reads from
  // "/input/doc".
  const preopen = new PreopenDirectory("/input", [
    ["doc", new File(inputBytes, { readonly: true })],
  ]);

  const stdoutChunks = [];
  const stderrChunks = [];
  const fds = [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((line) => stdoutChunks.push(line)),
    ConsoleStdout.lineBuffered((line) => stderrChunks.push(line)),
    preopen,
  ];

  const args = ["minipandoc", "-f", from, "-t", to];
  if (standalone) args.push("-s");
  args.push("/input/doc");

  const wasi = new WASI(args, [], fds);
  // wasi-sdk 25's wasi-libc imports env.__wasi_init_tp (thread-pointer init)
  // which isn't part of wasi_snapshot_preview1 and which the shim doesn't
  // supply. We have no threads, so a no-op stub is safe.
  const imports = {
    ...wasi.getImportObject(),
    env: { __wasi_init_tp: () => {} },
  };
  const instance = await WebAssembly.instantiate(wasmModule, imports);
  const code = wasi.start(instance);
  if (code !== 0) {
    const msg = stderrChunks.join("\n") || `minipandoc exited with code ${code}`;
    throw new Error(msg);
  }
  // The binary's writers always terminate in a single \n, which the line
  // buffer has already consumed; rejoin and restore it.
  return stdoutChunks.join("\n") + (stdoutChunks.length ? "\n" : "");
}
