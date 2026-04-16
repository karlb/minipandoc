//! Template engine tests.
//!
//! Covers: standalone HTML structure (default template), custom
//! template via `--template`, variable passthrough via `-V`, conditional
//! / loop directives via `-M`, the whitespace rule for line-only
//! directives, and a unit test that exercises `pandoc.template.apply`
//! through a Lua filter.

mod common;

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn fixtures() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.extend(["tests", "fixtures"]);
    p
}

fn run_minipandoc(args: &[&str], input: Option<&Path>) -> String {
    let mut cmd = Command::new(common::binary_path());
    cmd.args(args);
    if let Some(p) = input {
        cmd.arg(p);
    }
    let out = cmd
        .stderr(Stdio::inherit())
        .output()
        .expect("spawn minipandoc");
    assert!(
        out.status.success(),
        "minipandoc {:?} failed: {}",
        args,
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).expect("utf8")
}

#[test]
fn standalone_html_uses_default_template() {
    let fx = fixtures().join("meta.native");
    let html = run_minipandoc(&["-f", "native", "-t", "html", "-s"], Some(&fx));
    assert!(html.starts_with("<!DOCTYPE html>"), "doctype missing:\n{html}");
    assert!(html.contains("<title>A Document</title>"), "title missing:\n{html}");
    assert!(
        html.contains(r#"<meta name="generator" content="minipandoc"#),
        "generator meta missing:\n{html}"
    );
    assert!(html.contains("<p class=\"author\">Alice</p>"));
    assert!(html.contains("<p class=\"author\">Bob</p>"));
    assert!(html.contains("<p class=\"date\">2024-01-01</p>"));
    assert!(html.contains("</html>"));
}

#[test]
fn custom_template_overrides_default() {
    let fx = fixtures().join("meta.native");
    let tpl = fixtures().join("templates").join("custom.html");
    let out = run_minipandoc(
        &[
            "-f", "native", "-t", "html", "-s",
            "--template", tpl.to_str().unwrap(),
        ],
        Some(&fx),
    );
    assert!(out.starts_with("[[A Document]]\n"), "unexpected output:\n{out}");
    assert!(out.contains("<h1 id=\"heading\">Heading</h1>"), "body missing:\n{out}");
}

#[test]
fn variables_reach_template() {
    let fx = fixtures().join("meta.native");
    let tpl = fixtures().join("templates").join("varprobe.html");
    let out = run_minipandoc(
        &[
            "-f", "native", "-t", "html", "-s",
            "-V", "foo=bar",
            "--template", tpl.to_str().unwrap(),
        ],
        Some(&fx),
    );
    assert!(out.starts_with("VAR=bar\n"), "variable not interpolated:\n{out}");
}

#[test]
fn conditionals_loops_and_missing() {
    let fx = fixtures().join("meta.native");
    let tpl = fixtures().join("templates").join("probe.html");
    let out = run_minipandoc(
        &[
            "-f", "native", "-t", "html", "-s",
            "--template", tpl.to_str().unwrap(),
        ],
        Some(&fx),
    );
    // $if(title)$ branch fired.
    assert!(out.contains("TITLE: A Document"), "if branch failed:\n{out}");
    // $for(author)$ with $sep$.
    assert!(out.contains("Alice, Bob"), "for/sep failed:\n{out}");
    // $if(missing)$ branch did NOT fire.
    assert!(!out.contains("MISSING"), "missing var leaked into output:\n{out}");
    assert!(out.contains("DONE"), "after-conditional content missing:\n{out}");
}

#[test]
fn directive_alone_on_line_no_blank() {
    // The whitespace.html template is:
    //   START
    //   $if(title)$
    //   $title$
    //   $endif$
    //   END
    //   $body$
    // After applying with title="A Document", the output should be:
    //   START
    //   A Document
    //   END
    //   <body...>
    // No stray blank lines around the directives.
    let fx = fixtures().join("meta.native");
    let tpl = fixtures().join("templates").join("whitespace.html");
    let out = run_minipandoc(
        &[
            "-f", "native", "-t", "html", "-s",
            "--template", tpl.to_str().unwrap(),
        ],
        Some(&fx),
    );
    assert!(
        out.starts_with("START\nA Document\nEND\n"),
        "expected no blank lines between START/title/END, got:\n{out}"
    );
}

#[test]
fn template_apply_via_filter() {
    // Exercise pandoc.template.compile/apply directly through a Lua filter,
    // independent of the writer-side wiring.
    let tmp_dir = std::env::var("TMPDIR")
        .unwrap_or_else(|_| "/tmp".to_string());
    let filter_path = std::path::Path::new(&tmp_dir).join("template_apply_filter.lua");
    std::fs::write(
        &filter_path,
        r#"
return {
  Pandoc = function(d)
    local tpl = pandoc.template.compile("hello $name$, you have $n$ items")
    local s = pandoc.template.apply(tpl, { name = "world", n = 3 })
    table.insert(d.blocks, 1, pandoc.Para{ pandoc.Str(s) })
    return d
  end,
}
"#,
    )
    .unwrap();
    let fx = fixtures().join("meta.native");
    let out = run_minipandoc(
        &[
            "-f", "native", "-t", "native",
            "-L", filter_path.to_str().unwrap(),
        ],
        Some(&fx),
    );
    assert!(
        out.contains("hello world, you have 3 items"),
        "template.apply did not produce expected interpolation:\n{out}"
    );
}
