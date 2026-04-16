//! Integration tests: minipandoc -f native -t native on bundled fixtures.
//!
//! For each `.native` file in `tests/fixtures/`, assert:
//!   1. minipandoc succeeds.
//!   2. the output, when passed through `pandoc -f native -t native`,
//!      matches `pandoc -f native -t native <input>` byte-for-byte.
//!      (Semantic parity: same AST, even if pretty-printer differs.)
//!
//! If `pandoc` is not on PATH, semantic-parity checks are skipped with a
//! note; the minipandoc-only self-roundtrip idempotence check still runs.

mod common;

use std::path::PathBuf;
use std::process::{Command, Stdio};

fn fixtures_dir() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("tests");
    p.push("fixtures");
    p
}

fn run_minipandoc(input: &std::path::Path) -> String {
    let out = Command::new(common::binary_path())
        .args(["-f", "native", "-t", "native"])
        .arg(input)
        .stderr(Stdio::inherit())
        .output()
        .expect("spawn minipandoc");
    assert!(
        out.status.success(),
        "minipandoc failed on {}: {}",
        input.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).expect("utf8")
}

fn run_pandoc_native(input: &str) -> Option<String> {
    let out = Command::new("pandoc")
        .args(["-f", "native", "-t", "native"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .ok()?;
    use std::io::Write;
    out.stdin.as_ref()?;
    let mut child = out;
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .ok()?;
    let out = child.wait_with_output().ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8(out.stdout).ok()
}

#[test]
fn roundtrip_all_fixtures() {
    let dir = fixtures_dir();
    let has_pandoc = common::pandoc_available();
    if !has_pandoc {
        eprintln!("note: pandoc not on PATH — skipping semantic-parity checks");
    }
    let mut checked = 0;
    let mut entries: Vec<_> = std::fs::read_dir(&dir)
        .expect("read fixtures dir")
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().and_then(|s| s.to_str()) == Some("native"))
        .collect();
    entries.sort_by_key(|e| e.path());
    for entry in entries {
        let path = entry.path();
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        let original = std::fs::read_to_string(&path).unwrap();
        let our_output = run_minipandoc(&path);

        // Idempotence: running minipandoc on its own output should be stable.
        let our_tmp = tempfile(&our_output);
        let our_again = run_minipandoc(&our_tmp);
        assert_eq!(our_output, our_again, "{name}: minipandoc not idempotent");

        if has_pandoc {
            let pandoc_on_input = run_pandoc_native(&original)
                .expect("pandoc failed on fixture");
            let pandoc_on_output = run_pandoc_native(&our_output)
                .expect("pandoc failed on our output — output is not valid native");
            assert_eq!(
                pandoc_on_input, pandoc_on_output,
                "{name}: semantic parity with pandoc broken"
            );
        }
        checked += 1;
    }
    assert!(checked > 0, "no fixtures found");
}

fn tempfile(content: &str) -> PathBuf {
    use std::io::Write;
    let p = std::env::temp_dir().join(format!(
        "minipandoc-test-{}-{}.native",
        std::process::id(),
        rand_suffix()
    ));
    let mut f = std::fs::File::create(&p).unwrap();
    f.write_all(content.as_bytes()).unwrap();
    p
}

fn rand_suffix() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .subsec_nanos() as u64
}
