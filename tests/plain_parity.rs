//! Plain writer parity.
//!
//! For each `tests/fixtures/plain/*.native` fixture, byte-compare
//! `minipandoc -f native -t plain` against `pandoc -f native -t plain`.
//! Skips gracefully when pandoc is absent.
//!
//! Fixtures listed in `SMOKE_ONLY` are exercised only as smoke tests
//! (writer must run and emit non-empty output) — used for cases like
//! complex grid tables where matching pandoc's exact column-width
//! algorithm isn't worthwhile.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn binary_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("target");
    p.push(if cfg!(debug_assertions) { "debug" } else { "release" });
    p.push("minipandoc");
    p
}

fn fixtures_dir() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.extend(["tests", "fixtures", "plain"]);
    p
}

fn pandoc_available() -> bool {
    Command::new("pandoc")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn run_minipandoc(args: &[&str], input_path: &Path) -> String {
    let out = Command::new(binary_path())
        .args(args)
        .arg(input_path)
        .stderr(Stdio::inherit())
        .output()
        .expect("spawn minipandoc");
    assert!(
        out.status.success(),
        "minipandoc failed on {}: {}",
        input_path.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).expect("utf8")
}

fn run_pandoc_plain(input_path: &Path) -> String {
    let out = Command::new("pandoc")
        .args(["-f", "native", "-t", "plain"])
        .arg(input_path)
        .stderr(Stdio::inherit())
        .output()
        .expect("spawn pandoc");
    assert!(out.status.success(), "pandoc failed on {}", input_path.display());
    String::from_utf8(out.stdout).expect("utf8")
}

fn fixtures() -> Vec<PathBuf> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(fixtures_dir()).unwrap().flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) == Some("native") {
            out.push(p);
        }
    }
    out.sort();
    out
}

const SMOKE_ONLY: &[&str] = &[
    // Grid-table layout for multi-block cells; we emit a valid grid
    // table but byte-matching pandoc's exact widths isn't a goal.
    "complex_table.native",
];

fn is_smoke_only(p: &Path) -> bool {
    let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
    SMOKE_ONLY.contains(&name)
}

#[test]
fn plain_byte_parity() {
    if !pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping plain parity test");
        return;
    }
    let fxs = fixtures();
    assert!(!fxs.is_empty(), "no plain fixtures found");
    let mut failures: Vec<String> = Vec::new();
    for fx in fxs {
        let name = fx.file_name().unwrap().to_string_lossy().to_string();
        let ours = run_minipandoc(&["-f", "native", "-t", "plain"], &fx);
        if is_smoke_only(&fx) {
            assert!(!ours.trim().is_empty(), "{name}: smoke-only — empty output");
            continue;
        }
        let theirs = run_pandoc_plain(&fx);
        if ours != theirs {
            failures.push(format!(
                "--- {name} ---\n--- ours ---\n{ours}\n--- pandoc ---\n{theirs}\n"
            ));
        }
    }
    if !failures.is_empty() {
        panic!(
            "{} fixture(s) failed plain byte-parity:\n\n{}",
            failures.len(),
            failures.join("\n")
        );
    }
}

#[test]
fn plain_appears_in_list_formats() {
    let out = Command::new(binary_path())
        .arg("--list-output-formats")
        .output()
        .expect("spawn minipandoc");
    assert!(out.status.success());
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(
        text.lines().any(|l| l.trim() == "plain"),
        "expected 'plain' in output formats: {text}"
    );
}

/// `djot -> djot` round-trip on a fixture with a complex table must not
/// error: djot-writer falls back to `pandoc.write(table, "plain")` and
/// wraps the result in a code block. Before this commit, that call
/// errored because no `plain` writer existed.
#[test]
fn djot_complex_table_via_plain_fallback() {
    let mut djot_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    djot_path.extend(["tests", "fixtures", "plain", "complex_table.native"]);
    // Convert via djot -> djot. We start from native because we already
    // have the complex table fixture there.
    let djot_out = run_minipandoc(&["-f", "native", "-t", "djot"], &djot_path);
    assert!(!djot_out.trim().is_empty(), "djot output is empty");
    assert!(
        djot_out.contains("```"),
        "expected the complex table to be wrapped in a fenced code block:\n{djot_out}"
    );
}
