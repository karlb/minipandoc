//! CLI surface tests: list formats, stdin/stdout, -o file output, -M/-V flags.

mod common;

use std::ffi::OsString;
use std::path::PathBuf;
use std::process::Command;

use common::{run_minipandoc, TempDir};

#[test]
fn list_input_formats_includes_native() {
    let out = Command::new(common::binary_path())
        .arg("--list-input-formats")
        .output()
        .expect("spawn");
    assert!(out.status.success());
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(
        text.lines().any(|l| l.trim() == "native"),
        "expected 'native' in: {text}"
    );
}

#[test]
fn list_output_formats_includes_native() {
    let out = Command::new(common::binary_path())
        .arg("--list-output-formats")
        .output()
        .expect("spawn");
    assert!(out.status.success());
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(text.lines().any(|l| l.trim() == "native"));
}

#[test]
fn stdin_to_stdout() {
    let input = b"[Para [Str \"hi\"]]\n";
    let (ok, stdout, stderr) = run_minipandoc(
        &["-f", "native", "-t", "native"],
        input,
        None,
    );
    assert!(ok, "stderr: {stderr}");
    assert!(stdout.contains("Para"), "output: {stdout}");
    assert!(stdout.contains("Str \"hi\""), "output: {stdout}");
}

#[test]
fn output_file_flag() {
    let input_path = {
        let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        p.extend(["tests", "fixtures", "basic.native"]);
        p
    };
    let dir = TempDir::new("cli-out");
    let out_path = dir.path().join("out.native");

    let args: Vec<OsString> = vec![
        "-f".into(), "native".into(),
        "-t".into(), "native".into(),
        "-o".into(), out_path.clone().into(),
        input_path.into(),
    ];
    let (ok, _stdout, stderr) = run_minipandoc(&args, b"", None);
    assert!(ok, "stderr: {stderr}");
    let written = std::fs::read_to_string(&out_path).unwrap();
    assert!(!written.is_empty());
    assert!(written.contains("Header"));
}

#[test]
fn user_writer_script_resolves_as_path() {
    // A freestanding writer script passed by path.
    let writer_src = r#"
function Writer(doc, opts)
  return "HELLO " .. #doc.blocks
end
"#;
    let dir = TempDir::new("cli-writer");
    let writer = dir.path().join("hello-writer.lua");
    std::fs::write(&writer, writer_src).unwrap();

    let args: Vec<OsString> = vec![
        "-f".into(), "native".into(),
        "-t".into(), writer.into(),
    ];
    let (ok, stdout, stderr) = run_minipandoc(
        &args,
        b"[Para [Str \"a\"], Para [Str \"b\"]]",
        None,
    );
    assert!(ok, "stderr: {stderr}");
    assert_eq!(stdout.trim(), "HELLO 2");
}

// ---------------------------------------------------------------------------
// Error-path tests: these exercise the `eprintln!("minipandoc: {e}")` +
// `ExitCode::FAILURE` path in src/main.rs. A regression that silently
// succeeds on invalid input would be caught here.
// ---------------------------------------------------------------------------

#[test]
fn unknown_format_is_reported() {
    // Use an underscore-separated name so pandoc's `+ext`/`-ext`
    // extension parser doesn't split it apart.
    let (ok, stdout, stderr) = run_minipandoc(
        &["-f", "notarealformat_xyz", "-t", "native"],
        b"[Para [Str \"x\"]]",
        None,
    );
    assert!(!ok, "expected failure, got stdout={stdout}");
    assert!(
        stderr.contains("unknown format"),
        "expected 'unknown format' in stderr, got: {stderr}"
    );
    assert!(
        stderr.contains("notarealformat_xyz"),
        "expected format name in stderr, got: {stderr}"
    );
}

#[test]
fn missing_input_file_is_reported() {
    let dir = TempDir::new("cli-missing");
    let missing = dir.path().join("does-not-exist.native");
    let args: Vec<OsString> = vec![
        "-f".into(), "native".into(),
        "-t".into(), "native".into(),
        missing.clone().into(),
    ];
    let (ok, stdout, stderr) = run_minipandoc(&args, b"", None);
    assert!(!ok, "expected failure, got stdout={stdout}");
    assert!(
        stderr.contains(missing.to_str().unwrap()),
        "expected missing path in stderr, got: {stderr}"
    );
}

#[test]
fn malformed_lua_filter_is_reported() {
    // Syntactically broken Lua — must not silently succeed.
    let dir = TempDir::new("cli-badfilter");
    let filter = dir.path().join("bad.lua");
    std::fs::write(&filter, "this is not valid ( lua {{").unwrap();

    let args: Vec<OsString> = vec![
        "-f".into(), "native".into(),
        "-t".into(), "native".into(),
        "--lua-filter".into(), filter.clone().into(),
    ];
    let (ok, stdout, stderr) = run_minipandoc(
        &args,
        b"[Para [Str \"x\"]]",
        None,
    );
    assert!(
        !ok,
        "expected failure for malformed filter; stdout={stdout} stderr={stderr}"
    );
    assert!(
        stderr.contains(filter.to_str().unwrap()),
        "expected filter path in stderr, got: {stderr}"
    );
}
