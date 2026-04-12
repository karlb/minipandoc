//! CLI surface tests: list formats, stdin/stdout, -o file output, -M/-V flags.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn binary_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("target");
    p.push(if cfg!(debug_assertions) { "debug" } else { "release" });
    p.push("minipandoc");
    p
}

#[test]
fn list_input_formats_includes_native() {
    let out = Command::new(binary_path())
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
    let out = Command::new(binary_path())
        .arg("--list-output-formats")
        .output()
        .expect("spawn");
    assert!(out.status.success());
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(text.lines().any(|l| l.trim() == "native"));
}

#[test]
fn stdin_to_stdout() {
    let input = "[Para [Str \"hi\"]]\n";
    let mut child = Command::new(binary_path())
        .args(["-f", "native", "-t", "native"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let out = String::from_utf8(out.stdout).unwrap();
    assert!(out.contains("Para"), "output: {out}");
    assert!(out.contains("Str \"hi\""), "output: {out}");
}

#[test]
fn output_file_flag() {
    let input_path = {
        let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        p.extend(["tests", "fixtures", "basic.native"]);
        p
    };
    let out_path = std::env::temp_dir().join(format!(
        "mp-cli-out-{}.native",
        std::process::id()
    ));
    let status = Command::new(binary_path())
        .args(["-f", "native", "-t", "native", "-o"])
        .arg(&out_path)
        .arg(&input_path)
        .status()
        .unwrap();
    assert!(status.success());
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
    let writer = std::env::temp_dir().join(format!(
        "mp-hello-writer-{}.lua",
        std::process::id()
    ));
    std::fs::File::create(&writer)
        .unwrap()
        .write_all(writer_src.as_bytes())
        .unwrap();

    let mut child = Command::new(binary_path())
        .args(["-f", "native", "-t"])
        .arg(&writer)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(b"[Para [Str \"a\"], Para [Str \"b\"]]")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    assert_eq!(String::from_utf8(out.stdout).unwrap().trim(), "HELLO 2");
}
