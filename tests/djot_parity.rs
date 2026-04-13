//! Djot reader/writer parity.
//!
//! For each `.dj` fixture:
//!   Reader: `minipandoc -f djot -t native` normalizes equal to
//!           `pandoc -f vendor/djot-reader.lua -t native` (our bundled script).
//!   Writer: `minipandoc -f djot -t djot` equals byte-for-byte
//!           `pandoc -f vendor/djot-reader.lua -t vendor/djot-writer.lua`.
//!
//! Skips gracefully when pandoc is absent.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn binary_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("target");
    p.push(if cfg!(debug_assertions) { "debug" } else { "release" });
    p.push("minipandoc");
    p
}

fn vendor_dir() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.extend(["scripts", "vendor", "djot"]);
    p
}

fn fixtures_dir() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.extend(["tests", "fixtures", "djot"]);
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

fn run_minipandoc(args: &[&str], input_path: Option<&Path>) -> String {
    let mut cmd = Command::new(binary_path());
    cmd.args(args);
    if let Some(p) = input_path {
        cmd.arg(p);
    }
    let out = cmd
        .stderr(Stdio::inherit())
        .output()
        .expect("spawn minipandoc");
    assert!(
        out.status.success(),
        "minipandoc failed: args={args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).expect("utf8")
}

fn run_pandoc_with_vendor(reader_or_writer: &[&str], input: &Path) -> String {
    let vendor = vendor_dir();
    let lua_path = format!("{}/?.lua;;", vendor.display());
    let out = Command::new("pandoc")
        .env("LUA_PATH", lua_path)
        .args(reader_or_writer)
        .arg(input)
        .stderr(Stdio::inherit())
        .output()
        .expect("spawn pandoc");
    assert!(
        out.status.success(),
        "pandoc failed: args={reader_or_writer:?}"
    );
    String::from_utf8(out.stdout).unwrap()
}

fn run_pandoc_native(input: &str) -> String {
    let mut child = Command::new("pandoc")
        .args(["-f", "native", "-t", "native"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    String::from_utf8(out.stdout).unwrap()
}

fn fixtures() -> Vec<PathBuf> {
    let mut v: Vec<_> = std::fs::read_dir(fixtures_dir())
        .expect("read djot fixtures dir")
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("dj"))
        .collect();
    v.sort();
    v
}

#[test]
fn reader_semantic_parity() {
    if !pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping djot reader parity test");
        return;
    }
    let vendor = vendor_dir();
    let reader_script = vendor.join("djot-reader.lua");
    let fs = fixtures();
    assert!(!fs.is_empty(), "no djot fixtures");
    for fx in fs {
        let name = fx.file_name().unwrap().to_string_lossy().into_owned();
        let mp_native = run_minipandoc(&["-f", "djot", "-t", "native"], Some(&fx));
        let pd_native = run_pandoc_with_vendor(
            &["-f", reader_script.to_str().unwrap(), "-t", "native"],
            &fx,
        );
        assert_eq!(
            run_pandoc_native(&mp_native),
            run_pandoc_native(&pd_native),
            "{name}: reader parity broken"
        );
    }
}

#[test]
fn writer_byte_parity() {
    if !pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping djot writer parity test");
        return;
    }
    let vendor = vendor_dir();
    let reader_script = vendor.join("djot-reader.lua");
    let writer_script = vendor.join("djot-writer.lua");
    let fs = fixtures();
    for fx in fs {
        let name = fx.file_name().unwrap().to_string_lossy().into_owned();
        let mp_dj = run_minipandoc(&["-f", "djot", "-t", "djot"], Some(&fx));
        let pd_dj = run_pandoc_with_vendor(
            &[
                "-f",
                reader_script.to_str().unwrap(),
                "-t",
                writer_script.to_str().unwrap(),
            ],
            &fx,
        );
        assert_eq!(
            mp_dj, pd_dj,
            "{name}: writer output differs from pandoc running the same vendored script"
        );
    }
}

#[test]
fn djot_appears_in_list_formats() {
    let out = Command::new(binary_path())
        .arg("--list-input-formats")
        .output()
        .expect("spawn");
    assert!(out.status.success());
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(
        text.lines().any(|l| l.trim() == "djot"),
        "expected 'djot' in input formats: {text}"
    );

    let out = Command::new(binary_path())
        .arg("--list-output-formats")
        .output()
        .expect("spawn");
    assert!(out.status.success());
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(
        text.lines().any(|l| l.trim() == "djot"),
        "expected 'djot' in output formats: {text}"
    );
}
