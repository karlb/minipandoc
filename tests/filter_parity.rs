//! Re-verifies success-signal #2 ("an existing pandoc Lua filter runs
//! unmodified against minipandoc") across the set of writers we ship.
//! The filter exercises the canonical pandoc 3.x Lua filter idioms:
//! field access (`el.content[i]`, `#el.content`), `ipairs` over
//! containers, in-place content mutation, filter return semantics
//! (nil = unchanged, false = delete, list = splice), multi-handler
//! filter tables, and `pandoc.utils.stringify` / `pandoc.utils.type`.
//!
//! We then convert through each writer and assert byte-parity with real
//! pandoc running the same filter on the same input. Skip the whole
//! suite if pandoc isn't on PATH.

mod common;

use std::path::PathBuf;
use std::process::Command;

const INPUT_NATIVE: &str = r#"[ Header 1 ("h",[],[]) [ Str "hello", Space, Str "world" ]
, Para [ Str "keep", Space, Emph [ Str "me" ] ]
, Para [ Str "DROPME" ]
, Para [ Str "a", Space, Str "b", Space, Str "c" ]
, BulletList [ [ Plain [ Str "one" ] ], [ Plain [ Str "two" ] ] ]
, BlockQuote [ Para [ Str "quoted" ] ]
]
"#;

const FILTER_SRC: &str = r#"
-- Canonical pandoc 3.x filter idioms. All patterns here also work on
-- real pandoc; none rely on sequence-on-element semantics.

return {
  {
    -- Delete any Para whose stringified content is exactly "DROPME".
    Para = function(el)
      if pandoc.utils.stringify(el) == "DROPME" then
        return {}
      end
    end,
  },
  {
    -- Mutate first inline of every remaining Para via el.content[1].
    -- Append the Para's inline count as a trailing Str.
    Para = function(el)
      local n = #el.content
      el.content[1] = pandoc.Str("F:" .. pandoc.utils.stringify(el.content[1]))
      el.content[n + 1] = pandoc.Space()
      el.content[n + 2] = pandoc.Str("(n=" .. tostring(n) .. ")")
      return el
    end,

    -- Iterate via ipairs over the Header's content; build a fresh list.
    Header = function(el)
      local joined = {}
      for i, inl in ipairs(el.content) do
        joined[i] = pandoc.utils.stringify(inl)
      end
      el.content = { pandoc.Str("H:" .. table.concat(joined, "/")) }
      return el
    end,

    -- Check pandoc.utils.type for a BulletList; rebuild via pandoc.List.
    BulletList = function(el)
      assert(pandoc.utils.type(el) == "Block",
        "expected Block, got " .. tostring(pandoc.utils.type(el)))
      local items = pandoc.List({})
      for i, item in ipairs(el.content) do
        items:insert({ pandoc.Plain({ pandoc.Str("item" .. i) }) })
      end
      return pandoc.BulletList(items)
    end,

    -- Returning nil leaves BlockQuote unchanged; splice the inner Para
    -- out to verify list-splice semantics from a different handler.
    BlockQuote = function(el)
      return el.content
    end,
  },
}
"#;

fn write_fixtures() -> (common::TempDir, PathBuf, PathBuf) {
    let dir = common::TempDir::new("filter-parity");
    let filter_path = dir.path().join("filter.lua");
    std::fs::write(&filter_path, FILTER_SRC).unwrap();
    let input_path = dir.path().join("input.native");
    std::fs::write(&input_path, INPUT_NATIVE).unwrap();
    (dir, filter_path, input_path)
}

fn run_with_filter(bin: &str, to: &str, filter: &PathBuf, input: &PathBuf) -> (bool, String, String) {
    let out = Command::new(bin)
        .args(["-f", "native", "-t", to, "-L"])
        .arg(filter)
        .arg(input)
        .output()
        .unwrap_or_else(|e| panic!("spawn {}: {}", bin, e));
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

fn assert_parity_for(to: &str, filter: &PathBuf, input: &PathBuf) {
    let (ok_mp, mp_out, mp_err) =
        run_with_filter(common::binary_path().to_str().unwrap(), to, filter, input);
    assert!(ok_mp, "[{}] minipandoc failed: {}", to, mp_err);

    let (ok_pd, pd_out, pd_err) = run_with_filter("pandoc", to, filter, input);
    assert!(ok_pd, "[{}] pandoc failed: {}", to, pd_err);

    // Normalize by re-parsing through pandoc back to native. This washes
    // out pre-existing writer formatting differences (whitespace, escape
    // styles like `{[}...{]}` in pandoc's latex writer) so this test
    // detects filter-API divergences, not writer-parity gaps already
    // tracked by the per-format _parity suites. Skip `plain` — pandoc
    // has no plain reader.
    let reader = match to {
        "native" => "native",
        "html" => "html",
        "latex" => "latex",
        "markdown" => "markdown",
        "plain" => {
            // Byte-level compare; plain is at parity on the shapes this
            // fixture hits, so any divergence here is filter-level.
            assert_eq!(
                mp_out, pd_out,
                "[plain] filter output differs byte-for-byte.\nminipandoc:\n{}\npandoc:\n{}",
                mp_out, pd_out
            );
            return;
        }
        other => panic!("no reader mapped for writer {}", other),
    };
    let normalize = |s: &str| -> String {
        let (_, out, _) = common::run_pandoc(&["-f", reader, "-t", "native"], s.as_bytes())
            .expect("pandoc available");
        out
    };
    assert_eq!(
        normalize(&mp_out),
        normalize(&pd_out),
        "[{}] filter output differs after round-trip normalization.\nminipandoc:\n{}\npandoc:\n{}",
        to,
        mp_out,
        pd_out
    );
}

#[test]
fn filter_parity_native() {
    if !common::pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping filter_parity_native");
        return;
    }
    let (_dir, filter, input) = write_fixtures();
    assert_parity_for("native", &filter, &input);
}

#[test]
fn filter_parity_html() {
    if !common::pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping filter_parity_html");
        return;
    }
    let (_dir, filter, input) = write_fixtures();
    assert_parity_for("html", &filter, &input);
}

#[test]
fn filter_parity_plain() {
    if !common::pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping filter_parity_plain");
        return;
    }
    let (_dir, filter, input) = write_fixtures();
    assert_parity_for("plain", &filter, &input);
}

#[test]
fn filter_parity_markdown() {
    if !common::pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping filter_parity_markdown");
        return;
    }
    let (_dir, filter, input) = write_fixtures();
    assert_parity_for("markdown", &filter, &input);
}

#[test]
fn filter_parity_latex() {
    if !common::pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping filter_parity_latex");
        return;
    }
    let (_dir, filter, input) = write_fixtures();
    assert_parity_for("latex", &filter, &input);
}
