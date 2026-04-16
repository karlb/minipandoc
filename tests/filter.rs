//! Filter parity test: a simple Lua filter (uppercase Str text) applied via
//! `-L`. Output must equal pandoc's output for the same filter.

mod common;

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

#[test]
fn upper_filter_parity_with_pandoc() {
    if !common::pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping filter parity test");
        return;
    }
    // A filter that uppercases all Str text.
    let filter_src = r#"
function Str(el)
  el.text = el.text:upper()
  return el
end
"#;
    let filter_path = std::env::temp_dir().join("mp-upper-filter.lua");
    std::fs::File::create(&filter_path)
        .unwrap()
        .write_all(filter_src.as_bytes())
        .unwrap();

    let fixture = {
        let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        p.extend(["tests", "fixtures", "basic.native"]);
        p
    };

    let mp = Command::new(common::binary_path())
        .args(["-f", "native", "-t", "native", "-L"])
        .arg(&filter_path)
        .arg(&fixture)
        .output()
        .expect("spawn minipandoc");
    assert!(
        mp.status.success(),
        "minipandoc failed: {}",
        String::from_utf8_lossy(&mp.stderr)
    );
    let mp_out = String::from_utf8(mp.stdout).unwrap();

    let pd = Command::new("pandoc")
        .args(["-f", "native", "-t", "native", "-L"])
        .arg(&filter_path)
        .arg(&fixture)
        .output()
        .expect("spawn pandoc");
    assert!(pd.status.success());
    let pd_out = String::from_utf8(pd.stdout).unwrap();

    // Re-parse both through pandoc to normalize, then compare.
    let normalize = |s: &str| -> String {
        let mut p = Command::new("pandoc")
            .args(["-f", "native", "-t", "native"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        p.stdin
            .as_mut()
            .unwrap()
            .write_all(s.as_bytes())
            .unwrap();
        let out = p.wait_with_output().unwrap();
        String::from_utf8(out.stdout).unwrap()
    };
    assert_eq!(
        normalize(&mp_out),
        normalize(&pd_out),
        "filter output differs between minipandoc and pandoc"
    );
}
