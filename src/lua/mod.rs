use mlua::{Lua, Table, Value};

use crate::format::FormatRegistry;
use crate::options::{ReaderOptions, WriterOptions};

const PANDOC_MODULE_LUA: &str = include_str!("../../scripts/pandoc_module.lua");
const LAYOUT_LUA: &str = include_str!("../../scripts/layout.lua");
const TEMPLATE_LUA: &str = include_str!("../../scripts/template.lua");
const RE_LUA: &str = include_str!("../../scripts/vendor/lpeg/re.lua");

unsafe extern "C-unwind" {
    fn luaopen_lpeg(L: *mut mlua::ffi::lua_State) -> std::os::raw::c_int;
}

fn to_lua_err(e: impl std::fmt::Display) -> mlua::Error {
    mlua::Error::RuntimeError(e.to_string())
}

/// Build a fresh Lua state for a nested pandoc.read/pandoc.write call:
/// bootstrap pandoc, seed per-script globals, and load the format script.
fn new_sub_state(
    registry: &FormatRegistry,
    script: &crate::format::Script,
    format: &str,
    reader_opts: &ReaderOptions,
    writer_opts: &WriterOptions,
) -> Result<Lua, mlua::Error> {
    let sub = Lua::new();
    bootstrap(&sub, registry)?;
    set_globals(
        &sub,
        Some(format),
        reader_opts,
        writer_opts,
        script.path.as_deref(),
    )?;
    sub.load(&script.source).set_name(&script.name).exec()?;
    Ok(sub)
}

/// Initialize a fresh Lua state with the pandoc module loaded.
pub fn bootstrap(lua: &Lua, registry: &FormatRegistry) -> Result<(), mlua::Error> {
    // Preload lpeg (C module) and re (pure-Lua regex on top of lpeg).
    // Must happen before pandoc_module.lua runs so its `pcall(require,
    // "lpeg")` succeeds and exposes `pandoc.lpeg` / `pandoc.re`.
    let lpeg_fn = unsafe { lua.create_c_function(luaopen_lpeg)? };
    lua.preload_module("lpeg", lpeg_fn)?;
    let re_fn = lua.load(RE_LUA).set_name("re.lua").into_function()?;
    lua.preload_module("re", re_fn)?;

    let pandoc: Table = lua.load(PANDOC_MODULE_LUA).set_name("pandoc_module.lua").eval()?;
    lua.globals().set("pandoc", pandoc)?;
    // Load pandoc.layout on top of the pandoc table.
    let layout: Table = lua.load(LAYOUT_LUA).set_name("layout.lua").eval()?;
    let pandoc_tbl: Table = lua.globals().get("pandoc")?;
    pandoc_tbl.set("layout", layout)?;
    // Load pandoc.template (overrides the empty stub from pandoc_module).
    let template: Table = lua.load(TEMPLATE_LUA).set_name("template.lua").eval()?;
    let reg_t = registry.clone();
    let load_builtin = lua.create_function(move |_, name: String| {
        Ok(reg_t.load_template(&name))
    })?;
    template.set("_load_builtin", load_builtin)?;
    pandoc_tbl.set("template", template)?;
    lua.globals().set("PANDOC_VERSION", crate::PANDOC_VERSION)?;
    lua.globals().set("PANDOC_READER_OPTIONS", lua.create_table()?)?;
    lua.globals().set("PANDOC_WRITER_OPTIONS", lua.create_table()?)?;
    // Install pandoc.read and pandoc.write that recurse back into the registry.
    let pandoc: Table = lua.globals().get("pandoc")?;
    let reg_r = registry.clone();
    let reg_w = registry.clone();
    pandoc.set(
        "read",
        lua.create_function(move |lua, (text, format): (String, Option<String>)| {
            let format = format.unwrap_or_else(|| "markdown".to_string());
            let (base, exts) = crate::format::parse_extensions(&format);
            let script = reg_r.load_reader(&base).map_err(to_lua_err)?;
            let sub = new_sub_state(
                &reg_r,
                &script,
                &base,
                &ReaderOptions { extensions: exts, ..Default::default() },
                &WriterOptions::default(),
            )?;
            let reader: mlua::Function = get_fn(&sub, "Reader")
                .or_else(|| get_fn(&sub, "ByteStringReader"))
                .ok_or_else(|| {
                    mlua::Error::RuntimeError(format!(
                        "reader script {} defines neither Reader nor ByteStringReader",
                        base
                    ))
                })?;
            let opts = sub.globals().get::<Value>("PANDOC_READER_OPTIONS")?;
            let doc: Value = reader.call((text, opts))?;
            clone_value(lua, &sub, doc)
        })?,
    )?;
    pandoc.set(
        "write",
        lua.create_function(move |lua, (doc, format): (Value, Option<String>)| {
            let format = format.unwrap_or_else(|| "html".to_string());
            let (base, exts) = crate::format::parse_extensions(&format);
            let script = reg_w.load_writer(&base).map_err(to_lua_err)?;
            let sub = new_sub_state(
                &reg_w,
                &script,
                &base,
                &ReaderOptions::default(),
                &WriterOptions { extensions: exts, ..Default::default() },
            )?;
            let writer: mlua::Function = get_fn(&sub, "Writer").ok_or_else(|| {
                mlua::Error::RuntimeError(format!(
                    "writer script {} defines no Writer function",
                    base
                ))
            })?;
            let migrated = clone_value(&sub, lua, doc)?;
            let opts = sub.globals().get::<Value>("PANDOC_WRITER_OPTIONS")?;
            let out: String = writer.call((migrated, opts))?;
            Ok(out)
        })?,
    )?;

    // --- Resource helpers for --embed-resources ------------------------
    // pandoc.mediabag.fetch(source) -> (mime, contents) | (nil, err)
    // Local file reads only. URLs and data: sources are rejected so callers
    // can fall back to leaving the reference untouched.
    let mediabag: Table = pandoc.get("mediabag")?;
    mediabag.set(
        "fetch",
        lua.create_function(|lua, source: String| {
            if source.starts_with("http://")
                || source.starts_with("https://")
                || source.starts_with("data:")
            {
                let msg = lua.create_string(
                    &format!("remote fetching not supported: {source}"),
                )?;
                return Ok((Value::Nil, Value::String(msg)));
            }
            match std::fs::read(&source) {
                Ok(bytes) => {
                    let mime = guess_mime(&source);
                    Ok((
                        Value::String(lua.create_string(mime.as_bytes())?),
                        Value::String(lua.create_string(&bytes)?),
                    ))
                }
                Err(e) => Ok((
                    Value::Nil,
                    Value::String(lua.create_string(e.to_string().as_bytes())?),
                )),
            }
        })?,
    )?;

    // pandoc._internal.base64_encode(bytes) -> string
    let internal: Table = pandoc.get("_internal")?;
    internal.set(
        "base64_encode",
        lua.create_function(|lua, bytes: mlua::String| {
            let raw = bytes.as_bytes();
            let encoded = base64_encode(&raw);
            Ok(lua.create_string(encoded.as_bytes())?)
        })?,
    )?;

    // --- pandoc.zip -----------------------------------------------------------
    // pandoc.zip.create(entries) -> binary_string
    // entries: array of {path=string, data=string, method="stored"|"deflated"}
    let zip_table: Table = lua.create_table()?;
    zip_table.set(
        "create",
        lua.create_function(|lua, entries: Table| {
            use std::io::{Cursor, Write};
            let mut buf = Cursor::new(Vec::new());
            {
                let mut zw = zip::ZipWriter::new(&mut buf);
                for pair in entries.sequence_values::<Table>() {
                    let entry = pair?;
                    let path: mlua::String = entry.get("path")?;
                    let data: mlua::String = entry.get("data")?;
                    let method_str: Option<mlua::String> = entry.get("method")?;
                    let is_stored = method_str
                        .as_ref()
                        .and_then(|s| s.to_str().ok())
                        .map(|s| s == "stored")
                        .unwrap_or(false);
                    let method = if is_stored {
                        zip::CompressionMethod::Stored
                    } else {
                        zip::CompressionMethod::Deflated
                    };
                    let opts = zip::write::SimpleFileOptions::default()
                        .compression_method(method);
                    zw.start_file(path.to_str()?, opts).map_err(to_lua_err)?;
                    zw.write_all(&data.as_bytes()).map_err(to_lua_err)?;
                }
                zw.finish().map_err(to_lua_err)?;
            }
            Ok(lua.create_string(buf.into_inner())?)
        })?,
    )?;
    pandoc.set("zip", zip_table)?;

    Ok(())
}

/// Guess MIME type from a file path's extension. Used by
/// `pandoc.mediabag.fetch` to label embedded resources.
fn guess_mime(path: &str) -> &'static str {
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|s| s.to_str())
        .map(|s| s.to_ascii_lowercase());
    match ext.as_deref() {
        Some("png") => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("svg") => "image/svg+xml",
        Some("webp") => "image/webp",
        Some("bmp") => "image/bmp",
        Some("ico") => "image/x-icon",
        Some("pdf") => "application/pdf",
        Some("css") => "text/css",
        Some("js") => "application/javascript",
        Some("json") => "application/json",
        Some("html") | Some("htm") => "text/html",
        Some("txt") => "text/plain",
        _ => "application/octet-stream",
    }
}

/// Standard base64 encoder (RFC 4648, alphabet `A-Za-z0-9+/`, `=` padding).
/// Hand-rolled to avoid a crate dependency and keep the release binary small.
fn base64_encode(input: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((input.len() + 2) / 3 * 4);
    let mut chunks = input.chunks_exact(3);
    for c in &mut chunks {
        let n = ((c[0] as u32) << 16) | ((c[1] as u32) << 8) | (c[2] as u32);
        out.push(ALPHABET[((n >> 18) & 0x3f) as usize] as char);
        out.push(ALPHABET[((n >> 12) & 0x3f) as usize] as char);
        out.push(ALPHABET[((n >> 6) & 0x3f) as usize] as char);
        out.push(ALPHABET[(n & 0x3f) as usize] as char);
    }
    let rem = chunks.remainder();
    match rem.len() {
        0 => {}
        1 => {
            let n = (rem[0] as u32) << 16;
            out.push(ALPHABET[((n >> 18) & 0x3f) as usize] as char);
            out.push(ALPHABET[((n >> 12) & 0x3f) as usize] as char);
            out.push('=');
            out.push('=');
        }
        2 => {
            let n = ((rem[0] as u32) << 16) | ((rem[1] as u32) << 8);
            out.push(ALPHABET[((n >> 18) & 0x3f) as usize] as char);
            out.push(ALPHABET[((n >> 12) & 0x3f) as usize] as char);
            out.push(ALPHABET[((n >> 6) & 0x3f) as usize] as char);
            out.push('=');
        }
        _ => unreachable!(),
    }
    out
}

/// Set per-script globals. Call after bootstrap, before executing a user script.
pub fn set_globals(
    lua: &Lua,
    format: Option<&str>,
    reader_opts: &ReaderOptions,
    writer_opts: &WriterOptions,
    script_path: Option<&str>,
) -> Result<(), mlua::Error> {
    let globals = lua.globals();
    if let Some(f) = format {
        globals.set("FORMAT", f)?;
    } else {
        globals.set("FORMAT", "")?;
    }
    globals.set("PANDOC_READER_OPTIONS", reader_opts.to_lua(lua)?)?;
    globals.set("PANDOC_WRITER_OPTIONS", writer_opts.to_lua(lua)?)?;
    if let Some(p) = script_path {
        globals.set("PANDOC_SCRIPT_FILE", p)?;
    } else {
        globals.set("PANDOC_SCRIPT_FILE", Value::Nil)?;
    }
    Ok(())
}

pub(crate) fn get_fn(lua: &Lua, name: &str) -> Option<mlua::Function> {
    match lua.globals().get::<Value>(name).ok()? {
        Value::Function(f) => Some(f),
        _ => None,
    }
}

struct MetaTables {
    pandoc_mt: Table,
    element_mt: Table,
    inline_tags: Table,
    block_tags: Table,
}

impl MetaTables {
    fn fetch(dst: &Lua) -> Result<Self, mlua::Error> {
        let pandoc: Table = dst.globals().get("pandoc")?;
        let internal: Table = pandoc.get("_internal")?;
        Ok(Self {
            pandoc_mt: internal.get("Pandoc")?,
            element_mt: internal.get("Element")?,
            inline_tags: internal.get("INLINE_TAGS")?,
            block_tags: internal.get("BLOCK_TAGS")?,
        })
    }

    fn attach(&self, t: &Table, tag: &str) -> Result<(), mlua::Error> {
        if tag == "Pandoc" {
            let _ = t.set_metatable(Some(self.pandoc_mt.clone()));
            return Ok(());
        }
        let is_inline: bool = self.inline_tags.get::<Option<bool>>(tag)?.unwrap_or(false);
        let is_block: bool = self.block_tags.get::<Option<bool>>(tag)?.unwrap_or(false);
        if is_inline || is_block {
            let _ = t.set_metatable(Some(self.element_mt.clone()));
        }
        Ok(())
    }
}

/// Copy a Lua value from one state to another by serializing through primitive
/// types. Used when `pandoc.read`/`pandoc.write` runs a format script in a
/// nested Lua state.
pub fn clone_value(dst: &Lua, src: &Lua, v: Value) -> Result<Value, mlua::Error> {
    let mt = MetaTables::fetch(dst)?;
    clone_value_inner(dst, src, v, &mt)
}

fn clone_value_inner(
    dst: &Lua,
    src: &Lua,
    v: Value,
    mt: &MetaTables,
) -> Result<Value, mlua::Error> {
    match v {
        Value::Nil => Ok(Value::Nil),
        Value::Boolean(b) => Ok(Value::Boolean(b)),
        Value::Integer(i) => Ok(Value::Integer(i)),
        Value::Number(n) => Ok(Value::Number(n)),
        Value::String(s) => Ok(Value::String(dst.create_string(&s.as_bytes())?)),
        Value::Table(t) => clone_table(dst, src, t, mt).map(Value::Table),
        Value::Function(_) | Value::UserData(_) | Value::Thread(_) | Value::LightUserData(_)
        | Value::Error(_) | Value::Other(_) => {
            // Unsupported across states — return nil. Cross-state filter values
            // should be converted to tables first.
            Ok(Value::Nil)
        }
    }
}

fn clone_table(dst: &Lua, src: &Lua, t: Table, mt: &MetaTables) -> Result<Table, mlua::Error> {
    let out = dst.create_table()?;
    for pair in t.clone().pairs::<Value, Value>() {
        let (k, v) = pair?;
        let k2 = clone_value_inner(dst, src, k, mt)?;
        let v2 = clone_value_inner(dst, src, v, mt)?;
        out.set(k2, v2)?;
    }
    if let Ok(Value::String(tag)) = t.get::<Value>("tag") {
        mt.attach(&out, &tag.to_string_lossy())?;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::base64_encode;

    // RFC 4648 test vectors — cover every padding case (len mod 3 ∈ {0,1,2}).
    #[test]
    fn rfc4648_vectors() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(base64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
    }

    // 0xFF exercises the top bit of each sextet — catches accidental sign
    // extension or `& 0x3f` mistakes.
    #[test]
    fn high_bytes_and_boundaries() {
        assert_eq!(base64_encode(&[0xff]), "/w==");
        assert_eq!(base64_encode(&[0xff, 0xff]), "//8=");
        assert_eq!(base64_encode(&[0xff, 0xff, 0xff]), "////");
    }
}
