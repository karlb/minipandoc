//! `--embed-resources` end-to-end tests.
//!
//! Verify that the HTML writer inlines referenced images as base64 data URIs
//! and referenced stylesheets as `<style>` blocks, and that the flag implies
//! `--standalone`. These tests do not depend on a real pandoc being on PATH.

mod common;

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn unique_tmpdir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "mp-embed-{}-{}",
        tag,
        std::process::id()
    ));
    // Clean up any stale directory from a previous run with the same PID
    // (rare, but cheap to guard against).
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create tmpdir");
    dir
}

fn run_minipandoc_in(
    dir: &std::path::Path,
    args: &[&str],
    stdin_bytes: &[u8],
) -> (bool, String, String) {
    let mut child = Command::new(common::binary_path())
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn minipandoc");
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(stdin_bytes)
        .unwrap();
    let out = child.wait_with_output().expect("wait minipandoc");
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

/// A minimal PNG signature + a trivial 1×1 IHDR chunk. Our embed path only
/// base64-encodes the bytes, so these don't need to form a valid decodable
/// PNG — the magic prefix is enough to prove the data URI was emitted.
const PNG_BYTES: &[u8] = &[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // PNG signature
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, // IHDR length + tag
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89,
];

#[test]
fn embeds_image_as_data_uri() {
    let dir = unique_tmpdir("img");
    std::fs::write(dir.join("pixel.png"), PNG_BYTES).unwrap();

    let native =
        br#"[Para [Image ("",[],[]) [Str "alt"] ("pixel.png","")]]"# as &[u8];
    let (ok, stdout, stderr) = run_minipandoc_in(
        &dir,
        &["-f", "native", "-t", "html", "--embed-resources"],
        native,
    );
    assert!(ok, "minipandoc failed: stderr={stderr}\nstdout={stdout}");

    // The PNG signature `\x89PNG\r\n\x1a\n` base64-encodes to `iVBORw0KGgo`
    // as a prefix — a robust marker that the image was actually embedded.
    assert!(
        stdout.contains("data:image/png;base64,iVBORw0KGgo"),
        "expected embedded PNG data URI in output:\n{stdout}"
    );
    // The raw relative path must be gone.
    assert!(
        !stdout.contains("src=\"pixel.png\""),
        "expected original src to be replaced:\n{stdout}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn embeds_css_as_inline_style() {
    let dir = unique_tmpdir("css");
    std::fs::write(dir.join("x.css"), "body{color:red}").unwrap();

    let native = br#"[Para [Str "hi"]]"# as &[u8];
    let (ok, stdout, stderr) = run_minipandoc_in(
        &dir,
        &[
            "-f", "native", "-t", "html",
            "--embed-resources",
            "-V", "css=x.css",
        ],
        native,
    );
    assert!(ok, "minipandoc failed: stderr={stderr}\nstdout={stdout}");

    assert!(
        stdout.contains("<style>"),
        "expected <style> block in output:\n{stdout}"
    );
    assert!(
        stdout.contains("body{color:red}"),
        "expected CSS body to be inlined:\n{stdout}"
    );
    assert!(
        !stdout.contains("<link rel=\"stylesheet\""),
        "expected no <link rel=\"stylesheet\"> when embedding:\n{stdout}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn embed_resources_implies_standalone() {
    let dir = unique_tmpdir("sa");
    let native = br#"[Para [Str "hi"]]"# as &[u8];
    // Note: no explicit -s.
    let (ok, stdout, stderr) = run_minipandoc_in(
        &dir,
        &["-f", "native", "-t", "html", "--embed-resources"],
        native,
    );
    assert!(ok, "minipandoc failed: stderr={stderr}\nstdout={stdout}");
    assert!(
        stdout.starts_with("<!DOCTYPE html>"),
        "expected DOCTYPE at start (standalone), got:\n{}",
        stdout.chars().take(80).collect::<String>()
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn unresolvable_image_falls_back_to_original_src() {
    let dir = unique_tmpdir("missing");
    let native =
        br#"[Para [Image ("",[],[]) [Str "x"] ("nope.png","")]]"# as &[u8];
    let (ok, stdout, stderr) = run_minipandoc_in(
        &dir,
        &["-f", "native", "-t", "html", "--embed-resources"],
        native,
    );
    assert!(ok, "minipandoc failed: stderr={stderr}\nstdout={stdout}");
    // Missing file -> leave original reference intact rather than erroring.
    assert!(
        stdout.contains("src=\"nope.png\""),
        "expected fallback to original src when fetch fails:\n{stdout}"
    );
    assert!(
        !stdout.contains("data:"),
        "expected no data URI when fetch fails:\n{stdout}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}
