//! Amalgamate vendored Lua sources into single bundled scripts used by
//! src/format.rs via include_str!.
//!
//! For each amalgamation, the output is a self-contained Lua chunk:
//!   1. Optional prelude (raw Lua executed before any requires).
//!   2. For each module, a `package.preload['foo'] = function() ... end`
//!      wrapper containing the module source.
//!   3. The main entry script appended verbatim.
//!
//! Outputs:
//!   $OUT_DIR/djot_reader.lua, $OUT_DIR/djot_writer.lua
//!   $OUT_DIR/markdown_reader.lua

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn main() {
    let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let djot_dir = manifest_dir.join("scripts/vendor/djot");
    let lunamark_dir = manifest_dir.join("scripts/lunamark");

    println!("cargo:rerun-if-changed=scripts/vendor/djot");
    println!("cargo:rerun-if-changed=scripts/lunamark");
    println!("cargo:rerun-if-changed=scripts/vendor/lpeg");
    println!("cargo:rerun-if-changed=scripts/readers/markdown.lua");

    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));

    // Compile LPeg against the same Lua headers mlua vendors. `lua-src`
    // is also an (indirect) dep of mlua-sys; Cargo dedupes so this only
    // adds the include-path lookup, no extra link artifact surfaces.
    let lua_artifacts = lua_src::Build::new().build(lua_src::Lua54);
    let lpeg = manifest_dir.join("scripts/vendor/lpeg");
    cc::Build::new()
        .files([
            "lpcap.c", "lpcode.c", "lpcset.c",
            "lpprint.c", "lptree.c", "lpvm.c",
        ].iter().map(|f| lpeg.join(f)))
        .include(lua_artifacts.include_dir())
        .warnings(false)
        .compile("lpeg");

    // --- Djot ---------------------------------------------------------------
    let djot_modules: Vec<(&str, PathBuf)> = [
        ("djot", "djot.lua"),
        ("djot.ast", "djot/ast.lua"),
        ("djot.attributes", "djot/attributes.lua"),
        ("djot.block", "djot/block.lua"),
        ("djot.filter", "djot/filter.lua"),
        ("djot.html", "djot/html.lua"),
        ("djot.inline", "djot/inline.lua"),
        ("djot.json", "djot/json.lua"),
    ]
    .iter()
    .map(|(name, rel)| (*name, djot_dir.join(rel)))
    .collect();

    // Upstream `djot-reader.lua` is missing `Renderer:url` / `Renderer:email`
    // handlers, so autolinks (`<https://example.com>`, `<foo@example.com>`)
    // crash dispatch (`render_node` does `self[node.tag]`). Both node types
    // carry `.destination` and string-content children — exactly what
    // `Renderer:link` already consumes — so a two-line alias suffices.
    // `Renderer` is a file-local upvalue captured by the `Reader(input)`
    // closure; appending the assignment after the main source mutates the
    // same table the closure sees. Filed upstream; revert when fixed.
    let djot_reader_epilogue = "\n\
        Renderer.url = Renderer.link\n\
        Renderer.email = Renderer.link\n";
    amalgamate(
        &out_dir.join("djot_reader.lua"),
        "",
        &djot_modules,
        &djot_dir.join("djot-reader.lua"),
        djot_reader_epilogue,
    );
    amalgamate(
        &out_dir.join("djot_writer.lua"),
        "",
        &djot_modules,
        &djot_dir.join("djot-writer.lua"),
        "",
    );

    // --- Markdown (lunamark) ------------------------------------------------
    // `lunamark.util` does a top-level `require("cosmo")` (a Lua template
    // library used only by `util.sepby`, which the reader never calls).
    // Stub cosmo so the require succeeds without vendoring yet another
    // dependency. `sepby` would error if ever invoked — acceptable because
    // the reader path doesn't touch it.
    //
    // Similarly, lunamark probes for `lua-utf8` / `slnunicode` for
    // reference-link case folding. Lua 5.4's standard `utf8` module
    // covers entities.lua (utf8.char) but has no lower-case helper.
    // Expose `string.lower` under the lua-utf8 name — ASCII-only folding
    // is a known MVP limitation called out in CLAUDE.md.
    let markdown_prelude = "\
package.preload['cosmo'] = function() return {} end
package.preload['lua-utf8'] = function()
  return { lower = string.lower, char = utf8.char }
end
";
    let markdown_modules: Vec<(&str, PathBuf)> = vec![
        ("lunamark.util",            lunamark_dir.join("lunamark/util.lua")),
        ("lunamark.entities",        lunamark_dir.join("lunamark/entities.lua")),
        ("lunamark.reader.markdown", lunamark_dir.join("lunamark/reader/markdown.lua")),
    ];
    amalgamate(
        &out_dir.join("markdown_reader.lua"),
        markdown_prelude,
        &markdown_modules,
        &manifest_dir.join("scripts/readers/markdown.lua"),
        "",
    );
}

/// Bundle a list of Lua modules plus a main entry script into a single
/// self-contained chunk. Output format:
///
///   <prelude>
///   package.preload['mod.a'] = loadstring([[ ... ]])
///   ...
///   <main entry source>
fn amalgamate(
    out: &Path,
    prelude: &str,
    modules: &[(&str, PathBuf)],
    main: &Path,
    epilogue: &str,
) {
    let mut buf = String::new();
    buf.push_str("-- GENERATED by build.rs — do not edit.\n");
    if !prelude.is_empty() {
        buf.push_str(prelude);
        buf.push('\n');
    }
    for (mod_name, src_path) in modules {
        let source = fs::read_to_string(src_path)
            .unwrap_or_else(|e| panic!("read {}: {e}", src_path.display()));
        // Choose a long-equals delimiter that's not present in the source.
        let mut eqs = 1;
        loop {
            let close = format!("]{}]", "=".repeat(eqs));
            if !source.contains(&close) {
                break;
            }
            eqs += 1;
        }
        let eq = "=".repeat(eqs);
        buf.push_str(&format!(
            "package.preload[{:?}] = assert(loadstring or load)([{eq}[\n",
            mod_name
        ));
        buf.push_str(&source);
        buf.push_str(&format!("\n]{eq}])\n"));
    }
    let main_src = fs::read_to_string(main)
        .unwrap_or_else(|e| panic!("read {}: {e}", main.display()));
    buf.push('\n');
    buf.push_str(&main_src);
    if !epilogue.is_empty() {
        buf.push_str(epilogue);
    }
    fs::write(out, buf).unwrap_or_else(|e| panic!("write {}: {e}", out.display()));
}
