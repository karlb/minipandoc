//! WASI smoke test.
//!
//! Verifies the wasm32-wasip1 binary actually boots, loads mlua + Lua 5.4,
//! and runs a Lua-driven conversion. Skipped gracefully unless:
//!   - `target/wasm32-wasip1/release/minipandoc.wasm` exists (build it with
//!     `scripts/build-wasm.sh`), and
//!   - `node` is on PATH.
//!
//! This is explicitly a light smoke test — the full format parity suite runs
//! against the native binary. We only assert here that the WASM runtime path
//! isn't broken.

use std::path::PathBuf;
use std::process::{Command, Stdio};

fn project_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn wasm_path() -> PathBuf {
    let mut p = project_root();
    p.extend(["target", "wasm32-wasip1", "release", "minipandoc.wasm"]);
    p
}

fn runner_path() -> PathBuf {
    let mut p = project_root();
    p.extend(["tests", "wasi", "run-wasi.mjs"]);
    p
}

fn node_available() -> bool {
    Command::new("node")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn run_wasi(args: &[&str]) -> std::process::Output {
    Command::new("node")
        .arg("--experimental-wasi-unstable-preview1")
        .arg(runner_path())
        .args(args)
        .stderr(Stdio::piped())
        .stdout(Stdio::piped())
        .output()
        .expect("spawn node")
}

#[test]
fn wasi_binary_lists_formats_and_converts() {
    if !wasm_path().exists() {
        eprintln!(
            "note: {} not built — skipping wasi smoke test \
             (run scripts/build-wasm.sh to generate it)",
            wasm_path().display()
        );
        return;
    }
    if !node_available() {
        eprintln!("note: node not on PATH — skipping wasi smoke test");
        return;
    }

    // --list-output-formats exercises the format registry + CLI path end-to-end.
    let out = run_wasi(&["--list-output-formats"]);
    assert!(
        out.status.success(),
        "node exited non-zero:\nstderr:\n{}\nstdout:\n{}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    let listed = String::from_utf8(out.stdout).expect("utf8");
    for required in ["djot", "html", "latex", "markdown", "native", "plain"] {
        assert!(
            listed.lines().any(|l| l.trim() == required),
            "missing format '{required}' in:\n{listed}"
        );
    }

    // djot → html exercises mlua + Lua 5.4 + vendored djot reader + the html
    // writer — the full pipeline in WASM.
    let mut fx = project_root();
    fx.extend(["tests", "fixtures", "djot", "basic.dj"]);
    let out = run_wasi(&[
        "-f",
        "djot",
        "-t",
        "html",
        fx.to_str().expect("fixture path utf8"),
    ]);
    assert!(
        out.status.success(),
        "djot→html conversion failed:\nstderr:\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let html = String::from_utf8(out.stdout).expect("utf8");
    assert!(
        html.contains("<h1>Hello</h1>"),
        "expected <h1>Hello</h1> in WASM output:\n{html}"
    );
    assert!(
        html.contains("<em>emph</em>"),
        "expected <em>emph</em> in WASM output:\n{html}"
    );
}
