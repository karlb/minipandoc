use std::collections::BTreeMap;
use std::path::PathBuf;

use mlua::{Lua, Value};
use thiserror::Error;

use crate::format::{parse_extensions, FormatRegistry};
use crate::lua::get_fn;

fn resolve_format_arg(arg: &str) -> (String, BTreeMap<String, bool>) {
    if (arg.contains('/') || arg.contains('.')) && std::path::Path::new(arg).is_file() {
        return (arg.to_string(), BTreeMap::new());
    }
    parse_extensions(arg)
}
use crate::lua::{bootstrap, set_globals};
use crate::options::{ReaderOptions, WriterOptions};

#[derive(Debug, Error)]
pub enum Error {
    #[error("{0}")]
    Io(String),
    #[error("unknown format: {0}")]
    UnknownFormat(String),
    #[error("lua error: {0}")]
    Lua(String),
    #[error("{0}")]
    Other(String),
}

impl From<mlua::Error> for Error {
    fn from(e: mlua::Error) -> Self {
        Error::Lua(e.to_string())
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e.to_string())
    }
}

pub struct Config {
    pub from: String,
    pub to: String,
    pub input_files: Vec<PathBuf>,
    pub output_file: Option<PathBuf>,
    pub lua_filters: Vec<PathBuf>,
    pub data_dir: Option<PathBuf>,
    pub standalone: bool,
    pub embed_resources: bool,
    pub metadata: Vec<(String, String)>,
    pub variables: Vec<(String, String)>,
    pub columns: i64,
    pub wrap: String,
    pub template: Option<String>,
}

pub fn run(cfg: &Config) -> Result<(), Error> {
    let input = read_input(&cfg.input_files)?;
    let registry = FormatRegistry::new(cfg.data_dir.clone());

    // Prepare options. If the format argument refers to an existing file
    // (a user-supplied reader/writer script), bypass extension parsing.
    let (from_base, from_exts) = resolve_format_arg(&cfg.from);
    let (to_base, to_exts) = resolve_format_arg(&cfg.to);
    let reader_opts = ReaderOptions {
        extensions: from_exts,
        standalone: cfg.standalone,
        columns: cfg.columns,
    };
    let mut writer_opts = WriterOptions {
        extensions: to_exts,
        standalone: cfg.standalone,
        columns: cfg.columns,
        wrap: cfg.wrap.clone(),
        template: cfg.template.clone(),
        embed_resources: cfg.embed_resources,
        ..Default::default()
    };
    for (k, v) in &cfg.variables {
        writer_opts.variables.insert(k.clone(), v.clone());
    }

    // Load reader script
    let reader_script = registry.load_reader(&from_base)?;

    // Create Lua state for the reader.
    let lua = Lua::new();
    bootstrap(&lua, &registry)?;
    set_globals(
        &lua,
        Some(&from_base),
        &reader_opts,
        &writer_opts,
        reader_script.path.as_deref(),
    )?;
    lua.load(&reader_script.source)
        .set_name(&reader_script.name)
        .exec()?;
    // Apply top-level metadata
    {
        let pandoc: mlua::Table = lua.globals().get("pandoc")?;
        pandoc.set("_cli_metadata", kv_table(&lua, &cfg.metadata)?)?;
    }
    let reader_fn = get_fn(&lua, "Reader")
        .or_else(|| get_fn(&lua, "ByteStringReader"))
        .ok_or_else(|| {
            Error::Other(format!(
                "reader {} defines neither Reader nor ByteStringReader",
                from_base
            ))
        })?;
    let opts_t = lua.globals().get::<Value>("PANDOC_READER_OPTIONS")?;
    let mut doc: Value = reader_fn.call((input.as_str(), opts_t))?;

    // Apply CLI --metadata by merging into doc.meta
    if !cfg.metadata.is_empty() {
        if let Value::Table(ref dt) = doc {
            let meta: Value = dt.get("meta").unwrap_or(Value::Nil);
            let meta_t: mlua::Table = match meta {
                Value::Table(t) => t,
                _ => {
                    let t = lua.create_table()?;
                    dt.set("meta", t.clone())?;
                    t
                }
            };
            for (k, v) in &cfg.metadata {
                meta_t.set(k.as_str(), v.as_str())?;
            }
        }
    }

    for filter_path in &cfg.lua_filters {
        doc = apply_filter(&lua, filter_path, doc)?;
    }

    let writer_script = registry.load_writer(&to_base)?;
    set_globals(
        &lua,
        Some(&to_base),
        &reader_opts,
        &writer_opts,
        writer_script.path.as_deref(),
    )?;
    lua.load(&writer_script.source)
        .set_name(&writer_script.name)
        .exec()?;
    let byte_writer_fn = get_fn(&lua, "ByteStringWriter");
    let text_writer_fn = get_fn(&lua, "Writer");
    let wopts_t = lua.globals().get::<Value>("PANDOC_WRITER_OPTIONS")?;

    match (byte_writer_fn, text_writer_fn) {
        (Some(bw), _) => {
            let out: mlua::String = bw.call((doc, wopts_t))?;
            let bytes = out.as_bytes();
            match &cfg.output_file {
                Some(p) => std::fs::write(p, &*bytes)
                    .map_err(|e| Error::Io(format!("{}: {e}", p.display())))?,
                None => {
                    use std::io::Write;
                    std::io::stdout().lock().write_all(&bytes)?;
                }
            }
        }
        (_, Some(tw)) => {
            let mut out: String = tw.call((doc, wopts_t))?;
            // Mimic pandoc: terminate output with a single trailing newline.
            if !out.ends_with('\n') {
                out.push('\n');
            }
            match &cfg.output_file {
                Some(p) => std::fs::write(p, out)
                    .map_err(|e| Error::Io(format!("{}: {e}", p.display())))?,
                None => {
                    use std::io::Write;
                    std::io::stdout().lock().write_all(out.as_bytes())?;
                }
            }
        }
        _ => {
            return Err(Error::Other(format!(
                "writer {} defines neither Writer nor ByteStringWriter",
                to_base
            )));
        }
    }
    Ok(())
}

fn read_input(files: &[PathBuf]) -> Result<String, Error> {
    use std::io::Read;
    if files.is_empty() || (files.len() == 1 && files[0].as_os_str() == "-") {
        let mut buf = String::new();
        std::io::stdin().read_to_string(&mut buf)?;
        return Ok(buf);
    }
    let mut buf = String::new();
    for f in files {
        let piece = std::fs::read_to_string(f)?;
        if !buf.is_empty() {
            buf.push('\n');
        }
        buf.push_str(&piece);
    }
    Ok(buf)
}


fn kv_table(lua: &Lua, kv: &[(String, String)]) -> Result<mlua::Table, mlua::Error> {
    let t = lua.create_table()?;
    for (k, v) in kv {
        t.set(k.as_str(), v.as_str())?;
    }
    Ok(t)
}

fn apply_filter(
    lua: &Lua,
    filter_path: &std::path::Path,
    doc: Value,
) -> Result<Value, Error> {
    let src = std::fs::read_to_string(filter_path)?;
    let chunk_name = filter_path.display().to_string();

    // Pandoc filters: the filter script may define top-level element-keyed
    // functions (Str, Para, Pandoc, Meta, ...), OR it may `return` one or more
    // filter tables.
    //
    // We first evaluate the chunk; if it returns a non-nil value, use that as
    // the filter list. Otherwise, we harvest from globals.

    // Save the globals we care about so we can tell what the filter defined.
    let filter_result: Value = lua
        .load(&src)
        .set_name(&chunk_name)
        .eval::<Value>()
        .unwrap_or(Value::Nil);

    let filters: Vec<mlua::Table> = match filter_result {
        Value::Table(t) => {
            // Is it one filter table or a list of filter tables?
            // A list of filter tables is array-like with only integer keys.
            let is_list = is_array_of_tables(&t);
            if is_list {
                let mut out = Vec::new();
                for pair in t.pairs::<i64, mlua::Table>() {
                    let (_, ft) = pair.map_err(|e| Error::Lua(e.to_string()))?;
                    out.push(ft);
                }
                out
            } else {
                vec![t]
            }
        }
        _ => {
            // Harvest from globals: any element-tag key with a function value.
            vec![harvest_global_filter(lua)?]
        }
    };

    let mut current = doc;
    for ft in filters {
        current = walk_with(lua, current, ft)?;
    }
    Ok(current)
}

fn is_array_of_tables(t: &mlua::Table) -> bool {
    for pair in t.clone().pairs::<Value, Value>() {
        let (k, v) = match pair {
            Ok(p) => p,
            Err(_) => return false,
        };
        if !matches!(k, Value::Integer(_)) {
            return false;
        }
        if !matches!(v, Value::Table(_)) {
            return false;
        }
    }
    t.len().unwrap_or(0) > 0
}

fn harvest_global_filter(lua: &Lua) -> Result<mlua::Table, Error> {
    let keys = [
        "Str", "Emph", "Strong", "Underline", "Strikeout", "Superscript", "Subscript",
        "SmallCaps", "Quoted", "Cite", "Code", "Space", "SoftBreak", "LineBreak", "Math",
        "RawInline", "Link", "Image", "Note", "Span", "Plain", "Para", "LineBlock",
        "CodeBlock", "RawBlock", "BlockQuote", "OrderedList", "BulletList",
        "DefinitionList", "Header", "HorizontalRule", "Table", "Figure", "Div", "Meta",
        "Pandoc", "Inline", "Block", "Inlines", "Blocks",
    ];
    let t = lua.create_table()?;
    let globals = lua.globals();
    for k in keys {
        if let Ok(Value::Function(f)) = globals.get::<Value>(k) {
            t.set(k, f)?;
        }
    }
    Ok(t)
}

fn walk_with(
    lua: &Lua,
    doc: Value,
    filter: mlua::Table,
) -> Result<Value, Error> {
    // Call doc:walk(filter) if doc is a Pandoc-shaped table with a walk method.
    if let Value::Table(ref dt) = doc {
        if let Ok(walk) = dt.get::<mlua::Function>("walk") {
            let out: Value = walk.call((dt.clone(), filter))?;
            return Ok(out);
        }
        // Fall back: use pandoc.utils or the bootstrap's walk_pandoc.
        let walk_fn: mlua::Function = lua.globals().get("walk_pandoc")?;
        let out: Value = walk_fn.call((dt.clone(), filter))?;
        return Ok(out);
    }
    Ok(doc)
}
