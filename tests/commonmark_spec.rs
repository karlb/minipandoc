//! M1 — CommonMark spec-suite pass rate for the markdown reader.
//!
//! Runs every example in `scripts/vendor/commonmark/spec.txt` through
//! `minipandoc -f markdown -t html` and reports the pass rate. This is a
//! scorecard, not a conformance guard — the top-level test is `#[ignore]`
//! so `cargo test` does not fail on unmet targets. Run explicitly with:
//!
//!     cargo test --test commonmark_spec -- --ignored --nocapture
//!
//! Output: overall pass rate, per-section pass rate, and the 10 worst
//! sections. Used to scope the CommonMark overhaul (ROADMAP Next #3).
//!
//! Skips gracefully if the vendored spec is missing.

mod common;

use std::path::PathBuf;

fn spec_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.extend(["scripts", "vendor", "commonmark", "spec.txt"]);
    p
}

struct Example {
    number: usize,
    section: String,
    markdown: String,
    expected_html: String,
}

/// Parse `spec.txt` into examples. Format: each example is a block opened
/// by a line starting with 32 backticks + " example", terminated by a line
/// of 32 backticks. Inside the block a single line `.` separates the
/// markdown input from the expected HTML. Sections are the most recent
/// `## ` heading.
fn parse_spec(spec: &str) -> Vec<Example> {
    const FENCE: &str = "````````````````````````````````";
    let mut out = Vec::new();
    let mut section = String::from("(pre-section)");
    let mut lines = spec.lines().peekable();
    let mut n = 0usize;
    while let Some(line) = lines.next() {
        if let Some(rest) = line.strip_prefix("## ") {
            section = rest.trim().to_string();
            continue;
        }
        if line.starts_with(FENCE) && line.trim_start_matches('`').trim() == "example" {
            n += 1;
            let mut md = String::new();
            let mut html = String::new();
            let mut seen_dot = false;
            for inner in lines.by_ref() {
                if inner.chars().all(|c| c == '`') && inner.len() >= FENCE.len() {
                    break;
                }
                if !seen_dot && inner == "." {
                    seen_dot = true;
                    continue;
                }
                if seen_dot {
                    html.push_str(inner);
                    html.push('\n');
                } else {
                    md.push_str(inner);
                    md.push('\n');
                }
            }
            out.push(Example {
                number: n,
                section: section.clone(),
                markdown: md.replace('\u{2192}', "\t"),
                expected_html: html.replace('\u{2192}', "\t"),
            });
        }
    }
    out
}

/// Normalize HTML so minipandoc and the spec can be compared fairly:
///
/// - strip trailing `/` inside void tags (`<br />` → `<br>`) — minipandoc
///   emits XHTML form, the spec uses HTML5;
/// - decode a small set of named/numeric entities in text nodes so
///   `&quot;` and `"` compare equal, etc;
/// - trim trailing whitespace on each line and collapse a trailing newline.
fn normalize(html: &str) -> String {
    let bytes = html.as_bytes();
    let mut out = String::with_capacity(html.len());
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'<' {
            if let Some(end) = find_tag_end(bytes, i) {
                let tag = &html[i..=end];
                out.push_str(&normalize_tag(tag));
                i = end + 1;
                continue;
            }
        }
        if b == b'&' {
            if let Some((decoded, len)) = decode_entity(&html[i..]) {
                out.push_str(&decoded);
                i += len;
                continue;
            }
        }
        if b < 0x80 {
            out.push(b as char);
            i += 1;
        } else {
            // Preserve multi-byte UTF-8 sequences verbatim.
            let ch_len = utf8_char_len(b);
            out.push_str(&html[i..i + ch_len]);
            i += ch_len;
        }
    }
    // Strip trailing whitespace per line.
    let mut s: String = out
        .lines()
        .map(|l| l.trim_end())
        .collect::<Vec<_>>()
        .join("\n");
    // Collapse blank lines that sit between a tag close and a tag open
    // (`>\n\s*\n<` → `>\n<`). This removes the blank lines minipandoc
    // emits between top-level blocks without touching whitespace inside
    // `<pre>` content.
    loop {
        let before = s.len();
        s = collapse_block_blanks(&s);
        if s.len() == before {
            break;
        }
    }
    while s.ends_with('\n') || s.ends_with(' ') {
        s.pop();
    }
    s
}

/// One pass of `>\n\s*\n<` → `>\n<`. Called in a fixed-point loop so
/// runs of three or more consecutive blank lines also collapse cleanly.
fn collapse_block_blanks(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'>' {
            let j = i + 1;
            if j < bytes.len() && bytes[j] == b'\n' {
                let mut k = j + 1;
                while k < bytes.len() && (bytes[k] == b' ' || bytes[k] == b'\t') {
                    k += 1;
                }
                if k < bytes.len() && bytes[k] == b'\n' {
                    out.push_str(">\n");
                    i = k + 1;
                    continue;
                }
            }
        }
        if b < 0x80 {
            out.push(b as char);
            i += 1;
        } else {
            let ch_len = utf8_char_len(b);
            out.push_str(&s[i..i + ch_len]);
            i += ch_len;
        }
    }
    out
}

/// Length of a UTF-8 character given its leading byte.
fn utf8_char_len(b: u8) -> usize {
    if b < 0x80 {
        1
    } else if b < 0xC0 {
        // continuation byte (shouldn't be called on these); treat as 1
        1
    } else if b < 0xE0 {
        2
    } else if b < 0xF0 {
        3
    } else {
        4
    }
}

/// Return the index of the closing `>` for a tag starting at `<` at `i`,
/// or `None` if no tag is found (in which case the caller treats `<` as
/// literal text).
fn find_tag_end(bytes: &[u8], i: usize) -> Option<usize> {
    let mut j = i + 1;
    let mut in_quote: Option<u8> = None;
    while j < bytes.len() {
        let c = bytes[j];
        if let Some(q) = in_quote {
            if c == q {
                in_quote = None;
            }
        } else if c == b'"' || c == b'\'' {
            in_quote = Some(c);
        } else if c == b'>' {
            return Some(j);
        } else if c == b'<' {
            return None;
        }
        j += 1;
    }
    None
}

/// Normalize one tag:
/// - lowercase the tag name (`<P>` → `<p>`), leaving attributes untouched;
/// - collapse ` />` or `/>` at the end into `>` for HTML5-style output.
fn normalize_tag(tag: &str) -> String {
    debug_assert!(tag.starts_with('<') && tag.ends_with('>'));
    let inner = &tag[1..tag.len() - 1];
    let inner = inner.trim_end_matches(['/', ' ', '\t']);
    let (name_end, _) = inner
        .char_indices()
        .find(|(_, c)| c.is_whitespace() || *c == '/')
        .unwrap_or((inner.len(), ' '));
    let (name, rest) = inner.split_at(name_end);
    let mut s = String::with_capacity(tag.len());
    s.push('<');
    s.push_str(&name.to_ascii_lowercase());
    s.push_str(rest);
    s.push('>');
    s
}

/// Decode a single HTML entity at the start of `s`. Returns
/// `(decoded, consumed_len)` when a known entity matches, else `None`.
/// Limited to the six that account for the vast majority of
/// spec-vs-minipandoc disagreements (`&amp; &lt; &gt; &quot; &apos; &#39;`).
fn decode_entity(s: &str) -> Option<(String, usize)> {
    let named = [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
        ("&#39;", "'"),
        ("&#34;", "\""),
    ];
    for (k, v) in named {
        if s.starts_with(k) {
            return Some((v.to_string(), k.len()));
        }
    }
    None
}

#[test]
#[ignore]
fn m1_scorecard() {
    let path = spec_path();
    if !path.exists() {
        eprintln!(
            "note: {} missing — run scripts/vendor/commonmark/update.sh",
            path.display()
        );
        return;
    }
    let spec = std::fs::read_to_string(&path).expect("read spec.txt");
    let examples = parse_spec(&spec);
    assert!(
        examples.len() >= 600,
        "expected ~650 examples, got {}",
        examples.len()
    );
    eprintln!("spec.txt: {} examples", examples.len());

    let mut failures: Vec<(usize, String)> = Vec::new();
    let mut section_totals: Vec<(String, usize, usize)> = Vec::new();
    let mut cur_section: Option<String> = None;

    for ex in &examples {
        if cur_section.as_deref() != Some(&ex.section) {
            section_totals.push((ex.section.clone(), 0, 0));
            cur_section = Some(ex.section.clone());
        }
        let row = section_totals.last_mut().unwrap();
        row.1 += 1;

        let (ok, stdout, _stderr) = common::run_minipandoc(
            &["-f", "markdown", "-t", "html"],
            ex.markdown.as_bytes(),
            None,
        );
        let got = if ok { normalize(&stdout) } else { String::new() };
        let want = normalize(&ex.expected_html);
        if ok && got == want {
            row.2 += 1;
        } else {
            failures.push((ex.number, ex.section.clone()));
        }
    }

    let pass = examples.len() - failures.len();
    let pct = (pass as f64) * 100.0 / (examples.len() as f64);
    eprintln!("\n== M1 CommonMark scorecard ==");
    eprintln!(
        "PASS: {} / {} ({:.2}%)",
        pass,
        examples.len(),
        pct
    );

    eprintln!("\nPer-section pass rate:");
    for (name, total, passed) in &section_totals {
        let pct = (*passed as f64) * 100.0 / (*total as f64);
        eprintln!("  [{:>5.1}%]  {:>3}/{:<3}  {}", pct, passed, total, name);
    }

    let mut ranked: Vec<&(String, usize, usize)> = section_totals
        .iter()
        .filter(|(_, t, _)| *t >= 3)
        .collect();
    ranked.sort_by(|a, b| {
        let pa = a.2 as f64 / a.1 as f64;
        let pb = b.2 as f64 / b.1 as f64;
        pa.partial_cmp(&pb).unwrap()
    });
    eprintln!("\n10 worst-scoring sections (>=3 examples):");
    for (name, total, passed) in ranked.iter().take(10) {
        let pct = (*passed as f64) * 100.0 / (*total as f64);
        eprintln!(
            "  [{:>5.1}%]  {:>3}/{:<3}  {}",
            pct, passed, total, name
        );
    }
}
