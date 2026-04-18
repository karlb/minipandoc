//! Empirical verification of the one-line fix we propose to
//! `tarleb/panluna` in `notes/panluna-pr-draft.md`.
//!
//! Drives `tests/panluna_fix_verification_filter.lua`, which loads
//! the vendored `scripts/vendor/panluna/panluna.lua` twice (unchanged
//! and with `elseif typ == 'table' then` rewritten to add
//! `and rope.tag == nil`), exercises `unrope` on a plain-table
//! pandoc element from our runtime, and asserts:
//!
//!   * unpatched → element silently flattened to empty (the bug).
//!   * patched   → element preserved intact.
//!
//! If both asserts hold, the PR draft is ready to send.

mod common;

use std::path::PathBuf;
use std::process::Command;

#[test]
fn panluna_unrope_fix_verification() {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let filter = manifest
        .join("tests")
        .join("panluna_fix_verification_filter.lua");
    let panluna = manifest
        .join("scripts")
        .join("vendor")
        .join("panluna")
        .join("panluna.lua");
    let fixture = manifest
        .join("tests")
        .join("fixtures")
        .join("basic.native");

    let out = Command::new(common::binary_path())
        .args(["-f", "native", "-t", "native", "-L"])
        .arg(&filter)
        .arg(&fixture)
        .env("MP_PANLUNA_PATH", &panluna)
        .output()
        .expect("spawn minipandoc");

    assert!(
        out.status.success(),
        "minipandoc failed:\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}
