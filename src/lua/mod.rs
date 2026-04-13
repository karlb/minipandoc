use mlua::{Lua, Table, Value};

use crate::format::FormatRegistry;
use crate::options::{ReaderOptions, WriterOptions};
use crate::pipeline::Error;

const PANDOC_MODULE_LUA: &str = include_str!("../../scripts/pandoc_module.lua");
const LAYOUT_LUA: &str = include_str!("../../scripts/layout.lua");
const TEMPLATE_LUA: &str = include_str!("../../scripts/template.lua");

pub struct LuaEngine {
    pub lua: Lua,
}

impl LuaEngine {
    pub fn new() -> Result<Self, Error> {
        let lua = Lua::new();
        // Load the pandoc module and stash it as a global.
        let chunk = lua.load(PANDOC_MODULE_LUA).set_name("pandoc_module.lua");
        let pandoc: Table = chunk.eval()?;
        lua.globals().set("pandoc", pandoc)?;
        // PANDOC_VERSION
        lua.globals()
            .set("PANDOC_VERSION", crate::PANDOC_VERSION)?;
        // Empty writer/reader options until a pipeline sets them
        lua.globals().set(
            "PANDOC_READER_OPTIONS",
            lua.create_table()?,
        )?;
        lua.globals().set(
            "PANDOC_WRITER_OPTIONS",
            lua.create_table()?,
        )?;
        Ok(Self { lua })
    }

    /// Return the `pandoc` global table.
    pub fn pandoc_module(&self) -> Result<Table, Error> {
        Ok(self.lua.globals().get::<Table>("pandoc")?)
    }

    /// Install `pandoc.read` and `pandoc.write`, which invoke the pipeline
    /// recursively.
    pub fn install_recursive_io(&self, registry: FormatRegistry) -> Result<(), Error> {
        let pandoc = self.pandoc_module()?;
        let registry_read = registry.clone();
        let registry_write = registry;

        let read_fn = self.lua.create_function(
            move |lua, (text, format): (String, Option<String>)| {
                let format = format.unwrap_or_else(|| "markdown".to_string());
                let (base, exts) = crate::format::parse_extensions(&format);
                let script = registry_read.load_reader(&base).map_err(to_lua_err)?;
                let sub = Lua::new();
                crate::lua::bootstrap(&sub, &registry_read)?;
                crate::lua::set_globals(
                    &sub,
                    Some(&base),
                    &ReaderOptions { extensions: exts, ..Default::default() },
                    &WriterOptions::default(),
                    script.path.as_deref(),
                )?;
                sub.load(&script.source).set_name(&script.name).exec()?;
                let reader: mlua::Function = sub
                    .globals()
                    .get::<Value>("Reader")
                    .ok()
                    .and_then(|v| if let Value::Function(f) = v { Some(f) } else { None })
                    .or_else(|| {
                        sub.globals()
                            .get::<Value>("ByteStringReader")
                            .ok()
                            .and_then(|v| if let Value::Function(f) = v { Some(f) } else { None })
                    })
                    .ok_or_else(|| {
                        mlua::Error::RuntimeError(format!(
                            "reader script {} defines neither Reader nor ByteStringReader",
                            &base
                        ))
                    })?;
                let opts = sub.globals().get::<Value>("PANDOC_READER_OPTIONS")?;
                let doc: Value = reader.call((text, opts))?;
                crate::lua::clone_value(lua, &sub, doc)
            },
        )?;
        pandoc.set("read", read_fn)?;

        let write_fn = self.lua.create_function(
            move |lua, (doc, format): (Value, Option<String>)| {
                let format = format.unwrap_or_else(|| "html".to_string());
                let (base, exts) = crate::format::parse_extensions(&format);
                let script = registry_write.load_writer(&base).map_err(to_lua_err)?;
                let sub = Lua::new();
                crate::lua::bootstrap(&sub, &registry_write)?;
                crate::lua::set_globals(
                    &sub,
                    Some(&base),
                    &ReaderOptions::default(),
                    &WriterOptions { extensions: exts, ..Default::default() },
                    script.path.as_deref(),
                )?;
                sub.load(&script.source).set_name(&script.name).exec()?;
                let writer: mlua::Function = sub
                    .globals()
                    .get::<Value>("Writer")
                    .ok()
                    .and_then(|v| if let Value::Function(f) = v { Some(f) } else { None })
                    .ok_or_else(|| {
                        mlua::Error::RuntimeError(format!(
                            "writer script {} defines no Writer function",
                            &base
                        ))
                    })?;
                let migrated = crate::lua::clone_value(&sub, lua, doc)?;
                let opts = sub.globals().get::<Value>("PANDOC_WRITER_OPTIONS")?;
                let out: String = writer.call((migrated, opts))?;
                Ok(out)
            },
        )?;
        pandoc.set("write", write_fn)?;

        Ok(())
    }
}

fn to_lua_err(e: impl std::fmt::Display) -> mlua::Error {
    mlua::Error::RuntimeError(e.to_string())
}

/// Initialize a fresh Lua state with the pandoc module loaded.
pub fn bootstrap(lua: &Lua, registry: &FormatRegistry) -> Result<(), mlua::Error> {
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
            let sub = Lua::new();
            bootstrap(&sub, &reg_r)?;
            set_globals(
                &sub,
                Some(&base),
                &ReaderOptions { extensions: exts, ..Default::default() },
                &WriterOptions::default(),
                script.path.as_deref(),
            )?;
            sub.load(&script.source).set_name(&script.name).exec()?;
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
            let sub = Lua::new();
            bootstrap(&sub, &reg_w)?;
            set_globals(
                &sub,
                Some(&base),
                &ReaderOptions::default(),
                &WriterOptions { extensions: exts, ..Default::default() },
                script.path.as_deref(),
            )?;
            sub.load(&script.source).set_name(&script.name).exec()?;
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
    Ok(())
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

fn get_fn(lua: &Lua, name: &str) -> Option<mlua::Function> {
    match lua.globals().get::<Value>(name).ok()? {
        Value::Function(f) => Some(f),
        _ => None,
    }
}

/// Copy a Lua value from one state to another by serializing through primitive
/// types. Used when `pandoc.read`/`pandoc.write` runs a format script in a
/// nested Lua state.
pub fn clone_value(dst: &Lua, src: &Lua, v: Value) -> Result<Value, mlua::Error> {
    match v {
        Value::Nil => Ok(Value::Nil),
        Value::Boolean(b) => Ok(Value::Boolean(b)),
        Value::Integer(i) => Ok(Value::Integer(i)),
        Value::Number(n) => Ok(Value::Number(n)),
        Value::String(s) => Ok(Value::String(dst.create_string(&s.as_bytes())?)),
        Value::Table(t) => clone_table(dst, src, t).map(Value::Table),
        Value::Function(_) | Value::UserData(_) | Value::Thread(_) | Value::LightUserData(_)
        | Value::Error(_) | Value::Other(_) => {
            // Unsupported across states — return nil. Cross-state filter values
            // should be converted to tables first.
            Ok(Value::Nil)
        }
    }
}

fn clone_table(dst: &Lua, src: &Lua, t: Table) -> Result<Table, mlua::Error> {
    let out = dst.create_table()?;
    for pair in t.clone().pairs::<Value, Value>() {
        let (k, v) = pair?;
        let k2 = clone_value(dst, src, k)?;
        let v2 = clone_value(dst, src, v)?;
        out.set(k2, v2)?;
    }
    // Preserve metatable tag if this looks like an AST element.
    if let Ok(Value::String(tag)) = t.get::<Value>("tag") {
        let tag_str = tag.to_string_lossy();
        attach_meta_by_tag(dst, &out, &tag_str)?;
    }
    Ok(out)
}

fn attach_meta_by_tag(dst: &Lua, t: &Table, tag: &str) -> Result<(), mlua::Error> {
    let pandoc: Table = dst.globals().get("pandoc")?;
    let internal: Table = pandoc.get("_internal")?;
    // For Pandoc top-level, use the Pandoc metatable.
    if tag == "Pandoc" {
        let mt: Table = internal.get("Pandoc")?;
        let _ = t.set_metatable(Some(mt));
        return Ok(());
    }
    // Element metatable covers Block/Inline.
    let inline_tags: Table = internal.get("INLINE_TAGS")?;
    let block_tags: Table = internal.get("BLOCK_TAGS")?;
    let is_inline: bool = inline_tags.get::<Option<bool>>(tag)?.unwrap_or(false);
    let is_block: bool = block_tags.get::<Option<bool>>(tag)?.unwrap_or(false);
    if is_inline || is_block {
        let mt: Table = internal.get("Element")?;
        let _ = t.set_metatable(Some(mt));
    }
    Ok(())
}
