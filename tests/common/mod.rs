#![allow(dead_code)]

use std::ffi::OsStr;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

pub fn binary_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("target");
    p.push(if cfg!(debug_assertions) { "debug" } else { "release" });
    p.push("minipandoc");
    p
}

pub fn pandoc_available() -> bool {
    Command::new("pandoc")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// RAII temp directory. Created under `std::env::temp_dir()` with a
/// per-process unique suffix (PID + monotonic counter) so parallel tests
/// and rapid reruns never collide. Removed on drop; errors ignored.
pub struct TempDir {
    path: PathBuf,
}

impl TempDir {
    pub fn new(tag: &str) -> Self {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "mp-{}-{}-{}",
            tag,
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create tempdir");
        TempDir { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

/// Spawn the minipandoc binary with the given args, optionally piping
/// `stdin` and setting the working directory. Returns
/// `(success, stdout, stderr)` with output captured as UTF-8 lossy.
pub fn run_minipandoc<S: AsRef<OsStr>>(
    args: &[S],
    stdin: &[u8],
    cwd: Option<&Path>,
) -> (bool, String, String) {
    let mut cmd = Command::new(binary_path());
    for a in args {
        cmd.arg(a);
    }
    if let Some(d) = cwd {
        cmd.current_dir(d);
    }
    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn minipandoc");
    if !stdin.is_empty() {
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(stdin)
            .expect("write stdin");
    }
    // Drop stdin to signal EOF even when no bytes are piped.
    drop(child.stdin.take());
    let out = child.wait_with_output().expect("wait minipandoc");
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

/// Run `pandoc` with the given args and stdin. Returns `None` if pandoc is
/// not on PATH so callers can skip cleanly.
pub fn run_pandoc(args: &[&str], stdin: &[u8]) -> Option<(bool, String, String)> {
    if !pandoc_available() {
        return None;
    }
    let mut child = Command::new("pandoc")
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn pandoc");
    if !stdin.is_empty() {
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(stdin)
            .expect("write stdin");
    }
    drop(child.stdin.take());
    let out = child.wait_with_output().expect("wait pandoc");
    Some((
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    ))
}
