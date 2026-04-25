//! Compatibility parity for `gemtext.lua`, the pandoc-API custom writer at
//! https://github.com/karlb/gemtext.lua.
//!
//! Verifies that the unmodified writer (using `Writer(doc, opts)` and
//! `PANDOC_VERSION:must_be_at_least`) runs against minipandoc and matches its
//! own bundled fixtures.
//!
//! Locates the sister repo via `GEMTEXT_LUA_PATH` (path to `gemtext.lua`) or a
//! `../gemtext.lua/gemtext.lua` sibling fallback. Skips cleanly if neither is
//! present so CI in unrelated environments still passes.

mod common;

use std::path::{Path, PathBuf};

fn locate_writer() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("GEMTEXT_LUA_PATH") {
        let path = PathBuf::from(p);
        if path.is_file() {
            return Some(path);
        }
    }
    let mut sibling = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    sibling.pop();
    sibling.push("gemtext.lua");
    sibling.push("gemtext.lua");
    if sibling.is_file() {
        return Some(sibling);
    }
    None
}

/// Parse one `.test` file. Mirrors the bash runner's grammar: each case is
/// optional preamble lines (the first non-blank line is the label) followed by
/// a fenced block whose body is `<input>\n.\n<expected>` with the same fence
/// length opening and closing.
struct Case {
    label: String,
    line: usize,
    input: String,
    expected: String,
}

fn parse_cases(file: &Path) -> Vec<Case> {
    let body = std::fs::read_to_string(file).expect("read fixture");
    let mut cases = Vec::new();
    let mut state = State::Preamble;
    let mut desc = String::new();
    let mut input = String::new();
    let mut expected = String::new();
    let mut fence = String::new();
    let mut case_line = 0usize;

    enum State { Preamble, Input, Expected }

    for (i, line) in body.lines().enumerate() {
        let lineno = i + 1;
        match state {
            State::Preamble => {
                if let Some(rest) = line.strip_prefix("```") {
                    let extra = rest.bytes().take_while(|b| *b == b'`').count();
                    fence = "`".repeat(3 + extra);
                    state = State::Input;
                    case_line = lineno;
                } else {
                    desc.push_str(line);
                    desc.push('\n');
                }
            }
            State::Input => {
                if line == "." {
                    state = State::Expected;
                } else {
                    input.push_str(line);
                    input.push('\n');
                }
            }
            State::Expected => {
                if line == fence {
                    let label = desc
                        .lines()
                        .find(|l| !l.trim().is_empty())
                        .unwrap_or("(case)")
                        .chars()
                        .take(60)
                        .collect::<String>();
                    cases.push(Case {
                        label,
                        line: case_line,
                        input: std::mem::take(&mut input),
                        expected: std::mem::take(&mut expected),
                    });
                    desc.clear();
                    state = State::Preamble;
                } else {
                    expected.push_str(line);
                    expected.push('\n');
                }
            }
        }
    }
    cases
}

#[test]
fn gemtext_writer_runs_unmodified_and_matches_fixtures() {
    let writer = match locate_writer() {
        Some(p) => p,
        None => {
            eprintln!(
                "gemtext.lua not found — set GEMTEXT_LUA_PATH or place the \
                 sister repo at ../gemtext.lua/. Skipping."
            );
            return;
        }
    };
    let test_dir = writer.parent().unwrap().join("test");
    if !test_dir.is_dir() {
        eprintln!("gemtext.lua/test/ missing — skipping.");
        return;
    }

    // Trailing-newline policy: minipandoc's text-writer pipeline guarantees a
    // single `\n` terminator (see CLAUDE.md). The fixture `expected` blocks
    // also end with `\n` because each line is collected with a `\n` appended.
    // No normalization needed.
    let writer_arg = writer.to_string_lossy().to_string();
    let mut total = 0usize;
    let mut failed = Vec::new();

    let mut entries: Vec<_> = std::fs::read_dir(&test_dir)
        .expect("read test dir")
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.path().extension().and_then(|s| s.to_str()) == Some("test")
        })
        .collect();
    entries.sort_by_key(|e| e.path());
    assert!(!entries.is_empty(), "no .test files in {}", test_dir.display());

    for entry in entries {
        let path = entry.path();
        let cases = parse_cases(&path);
        for case in cases {
            total += 1;
            let (ok, stdout, stderr) = common::run_minipandoc(
                &["-f", "djot", "-t", &writer_arg],
                case.input.as_bytes(),
                None,
            );
            if !ok {
                failed.push(format!(
                    "{}:{} ({}): minipandoc failed: {}",
                    path.file_name().unwrap().to_string_lossy(),
                    case.line,
                    case.label,
                    stderr.trim(),
                ));
                continue;
            }
            if stdout != case.expected {
                failed.push(format!(
                    "{}:{} ({}):\n--- expected\n{}--- actual\n{}",
                    path.file_name().unwrap().to_string_lossy(),
                    case.line,
                    case.label,
                    case.expected,
                    stdout,
                ));
            }
        }
    }

    if !failed.is_empty() {
        panic!(
            "{} of {} gemtext fixtures failed:\n\n{}",
            failed.len(),
            total,
            failed.join("\n\n")
        );
    }
    assert!(total > 0, "parsed zero cases — fixture grammar drift?");
    eprintln!("gemtext.lua parity: {total}/{total} cases pass");
}
