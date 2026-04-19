// Reference renderer for M2: reads markdown from stdin, writes HTML to
// stdout, using pulldown-cmark. Kept minimal so benchmark wall-clock is
// dominated by the parser itself, not harness overhead.

use std::io::{Read, Write};

use pulldown_cmark::{html, Options, Parser};

fn main() {
    let mut input = String::new();
    std::io::stdin()
        .read_to_string(&mut input)
        .expect("read stdin");
    let opts = Options::ENABLE_TABLES
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_HEADING_ATTRIBUTES;
    let parser = Parser::new_ext(&input, opts);
    let mut out = String::with_capacity(input.len());
    html::push_html(&mut out, parser);
    std::io::stdout()
        .write_all(out.as_bytes())
        .expect("write stdout");
}
