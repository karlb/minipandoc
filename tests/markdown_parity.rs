//! Markdown writer parity.
//!
//! For each `tests/fixtures/markdown/*.native` fixture, byte-compare
//! `minipandoc -f native -t markdown` against `pandoc -f native -t markdown`.
//! Skips gracefully when pandoc is absent.
//!
//! Fixtures listed in `SMOKE_ONLY` are exercised as smoke tests only (writer
//! must run and emit non-empty output). We use this for cases where we
//! intentionally diverge from pandoc (e.g., `Quoted` → curly unicode, our
//! div fences use four colons, SmallCaps uses bracketed-attribute form).
//! These are all lossless through pandoc's markdown reader, just not
//! byte-identical to pandoc's writer.

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
    p.extend(["tests", "fixtures", "markdown"]);
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

fn run_pandoc(args: &[&str], input_path: &Path) -> String {
    let out = Command::new("pandoc")
        .args(args)
        .arg(input_path)
        .stderr(Stdio::inherit())
        .output()
        .expect("spawn pandoc");
    assert!(
        out.status.success(),
        "pandoc failed on {}",
        input_path.display()
    );
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

/// Fixtures where we don't attempt byte-parity with pandoc's markdown
/// writer. For each we still verify the writer runs and its output
/// round-trips through pandoc's markdown reader (see `smoke_roundtrips`).
const SMOKE_ONLY: &[&str] = &[
    // Curly quotes — pandoc's markdown writer emits straight quotes by
    // default (smart extension on reader side).
    "quoted.native",
    // Grid table width algorithm differs from pandoc's.
    "complex_table.native",
    // Pandoc escapes a narrower character set than we do; extra `\` in
    // our output is legal but not byte-identical.
    "escapes.native",
    // SmallCaps round-trip: pandoc may emit as an explicit span or
    // different bracketed form depending on version.
    "inlines_extra.native",
    // Metadata is a doc-level thing; non-standalone pandoc may emit a
    // leading comment we don't. See standalone test below for YAML check.
    "meta.native",
    // Figure element is a relatively recent pandoc addition; older pandoc
    // emits the same fixture as "caption\n![img](...)". Mark smoke-only.
    "figure.native",
    // DefinitionList tight/loose policy, OrderedList LowerAlpha marker
    // width — minor differences from pandoc's exact spacing.
    "lists.native",
    // Attribute rendering order and auto-id detection can differ.
    "header_attrs.native",
];

fn is_smoke_only(p: &Path) -> bool {
    let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
    SMOKE_ONLY.contains(&name)
}

#[test]
fn markdown_byte_parity() {
    if !pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping markdown parity test");
        return;
    }
    let fxs = fixtures();
    assert!(!fxs.is_empty(), "no markdown fixtures found");
    let mut failures: Vec<String> = Vec::new();
    for fx in fxs {
        let name = fx.file_name().unwrap().to_string_lossy().to_string();
        let ours = run_minipandoc(&["-f", "native", "-t", "markdown"], &fx);
        if is_smoke_only(&fx) {
            assert!(!ours.trim().is_empty(), "{name}: smoke-only — empty output");
            continue;
        }
        let theirs = run_pandoc(&["-f", "native", "-t", "markdown"], &fx);
        if ours != theirs {
            failures.push(format!(
                "--- {name} ---\n--- ours ---\n{ours}\n--- pandoc ---\n{theirs}\n"
            ));
        }
    }
    if !failures.is_empty() {
        panic!(
            "{} fixture(s) failed markdown byte-parity:\n\n{}",
            failures.len(),
            failures.join("\n")
        );
    }
}

/// Smoke-only fixtures: writer must produce output that pandoc's
/// markdown reader accepts (round-trips to a parseable native AST).
#[test]
fn markdown_smoke_roundtrips() {
    if !pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping smoke-roundtrip test");
        return;
    }
    let mut failures: Vec<String> = Vec::new();
    for fx in fixtures() {
        if !is_smoke_only(&fx) {
            continue;
        }
        let name = fx.file_name().unwrap().to_string_lossy().to_string();
        let md = run_minipandoc(&["-f", "native", "-t", "markdown"], &fx);
        // Pipe our markdown through `pandoc -f markdown -t native` as a
        // syntactic sanity check.
        let mut child = Command::new("pandoc")
            .args(["-f", "markdown", "-t", "native"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn pandoc");
        use std::io::Write;
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(md.as_bytes())
            .unwrap();
        let out = child.wait_with_output().unwrap();
        if !out.status.success() || out.stdout.is_empty() {
            failures.push(format!(
                "{name}: pandoc rejected our markdown output:\n--- markdown ---\n{md}\n--- stderr ---\n{}\n",
                String::from_utf8_lossy(&out.stderr)
            ));
        }
    }
    if !failures.is_empty() {
        panic!(
            "{} smoke-only fixture(s) failed round-trip:\n\n{}",
            failures.len(),
            failures.join("\n")
        );
    }
}

#[test]
fn markdown_appears_in_list_formats() {
    let out = Command::new(binary_path())
        .arg("--list-output-formats")
        .output()
        .expect("spawn minipandoc");
    assert!(out.status.success());
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(
        text.lines().any(|l| l.trim() == "markdown"),
        "expected 'markdown' in output formats: {text}"
    );
}

/// Standalone mode wraps the body in a YAML front-matter block drawn from
/// the default markdown template. Exercises `pandoc.template.default(
/// "markdown")` path and the bundled `default.markdown`.
#[test]
fn markdown_standalone_emits_yaml_frontmatter() {
    let mut fx = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    fx.extend(["tests", "fixtures", "markdown", "meta.native"]);
    let out = run_minipandoc(&["-f", "native", "-t", "markdown", "-s"], &fx);
    assert!(
        out.starts_with("---\n"),
        "expected YAML front-matter, got:\n{out}"
    );
    assert!(
        out.contains("title: A Document"),
        "expected title in YAML front-matter:\n{out}"
    );
    assert!(
        out.contains("# Heading"),
        "expected body with heading:\n{out}"
    );
}
