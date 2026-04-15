use std::collections::BTreeMap;

use mlua::{Lua, Table};

#[derive(Clone, Debug, Default)]
pub struct ReaderOptions {
    pub extensions: BTreeMap<String, bool>,
    pub standalone: bool,
    pub columns: i64,
}

impl ReaderOptions {
    pub fn to_lua<'lua>(&self, lua: &'lua Lua) -> Result<Table, mlua::Error> {
        let t = lua.create_table()?;
        let exts = lua.create_table()?;
        for (k, v) in &self.extensions {
            exts.set(k.as_str(), *v)?;
        }
        t.set("extensions", exts)?;
        t.set("standalone", self.standalone)?;
        t.set("columns", self.columns)?;
        Ok(t)
    }
}

#[derive(Clone, Debug)]
pub struct WriterOptions {
    pub extensions: BTreeMap<String, bool>,
    pub standalone: bool,
    pub columns: i64,
    pub wrap: String,
    pub variables: BTreeMap<String, String>,
    pub template: Option<String>,
    pub embed_resources: bool,
}

impl Default for WriterOptions {
    fn default() -> Self {
        Self {
            extensions: BTreeMap::new(),
            standalone: false,
            columns: 72,
            wrap: "auto".to_string(),
            variables: BTreeMap::new(),
            template: None,
            embed_resources: false,
        }
    }
}

impl WriterOptions {
    pub fn to_lua<'lua>(&self, lua: &'lua Lua) -> Result<Table, mlua::Error> {
        let t = lua.create_table()?;
        let exts = lua.create_table()?;
        for (k, v) in &self.extensions {
            exts.set(k.as_str(), *v)?;
        }
        t.set("extensions", exts)?;
        t.set("standalone", self.standalone)?;
        t.set("columns", self.columns)?;
        t.set("wrap_text", self.wrap.as_str())?;
        t.set("embed_resources", self.embed_resources)?;
        let vars = lua.create_table()?;
        for (k, v) in &self.variables {
            vars.set(k.as_str(), v.as_str())?;
        }
        t.set("variables", vars)?;
        if let Some(tpl) = &self.template {
            t.set("template", tpl.as_str())?;
        }
        Ok(t)
    }
}
