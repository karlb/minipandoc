use std::path::PathBuf;

use clap::Parser;

use crate::format::{FormatRegistry, ScriptKind};
use crate::pipeline::{self, Config, Error};

#[derive(Debug, Parser)]
#[command(
    name = "minipandoc",
    about = "Pandoc-compatible document converter (Lua scripts only)",
    disable_version_flag = true,
)]
pub struct Cli {
    /// Input format (pandoc-style, e.g. `markdown+smart`)
    #[arg(short = 'f', long = "from", alias = "read")]
    pub from: Option<String>,

    /// Output format (pandoc-style)
    #[arg(short = 't', long = "to", alias = "write")]
    pub to: Option<String>,

    /// Output file (default: stdout)
    #[arg(short = 'o', long = "output")]
    pub output: Option<PathBuf>,

    /// Lua filter file (repeatable)
    #[arg(short = 'L', long = "lua-filter")]
    pub lua_filter: Vec<PathBuf>,

    /// Data directory (overrides default search path)
    #[arg(long = "data-dir")]
    pub data_dir: Option<PathBuf>,

    /// Metadata key or key=value (repeatable)
    #[arg(short = 'M', long = "metadata")]
    pub metadata: Vec<String>,

    /// Variable key or key=value (repeatable)
    #[arg(short = 'V', long = "variable")]
    pub variable: Vec<String>,

    /// Produce standalone output
    #[arg(short = 's', long = "standalone")]
    pub standalone: bool,

    /// Embed images and stylesheets as data URIs / inline blocks
    /// (implies --standalone)
    #[arg(long = "embed-resources")]
    pub embed_resources: bool,

    /// List input formats and exit
    #[arg(long = "list-input-formats")]
    pub list_input_formats: bool,

    /// List output formats and exit
    #[arg(long = "list-output-formats")]
    pub list_output_formats: bool,

    /// Print version and exit
    #[arg(long = "version")]
    pub version: bool,

    /// Input files (default: stdin)
    pub input_files: Vec<PathBuf>,

    // Recognized-but-stub pandoc flags (accepted so invocations don't error;
    // may be a no-op until later phases implement them).
    #[arg(long = "columns", default_value = "72")]
    pub columns: i64,

    #[arg(long = "wrap", default_value = "auto")]
    pub wrap: String,

    #[arg(long = "template")]
    pub template: Option<String>,
}

pub fn run() -> Result<(), Error> {
    let cli = Cli::parse();
    if cli.version {
        println!("minipandoc {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    if cli.list_input_formats {
        let reg = FormatRegistry::new(cli.data_dir.clone());
        for f in reg.list_formats(ScriptKind::Reader) {
            println!("{f}");
        }
        return Ok(());
    }
    if cli.list_output_formats {
        let reg = FormatRegistry::new(cli.data_dir.clone());
        for f in reg.list_formats(ScriptKind::Writer) {
            println!("{f}");
        }
        return Ok(());
    }
    let from = cli.from.as_deref().ok_or_else(|| {
        Error::Other("no --from format specified".to_string())
    })?;
    let to = cli.to.as_deref().ok_or_else(|| {
        Error::Other("no --to format specified".to_string())
    })?;
    let template = if let Some(path) = &cli.template {
        let p = std::path::Path::new(path);
        let body = std::fs::read_to_string(p)
            .map_err(|e| Error::Io(format!("{path}: {e}")))?;
        Some(body)
    } else {
        None
    };
    let cfg = Config {
        from: from.to_string(),
        to: to.to_string(),
        input_files: cli.input_files,
        output_file: cli.output,
        lua_filters: cli.lua_filter,
        data_dir: cli.data_dir,
        standalone: cli.standalone || cli.embed_resources,
        embed_resources: cli.embed_resources,
        metadata: parse_kv(&cli.metadata),
        variables: parse_kv(&cli.variable),
        columns: cli.columns,
        wrap: cli.wrap,
        template,
    };
    pipeline::run(&cfg)
}

fn parse_kv(items: &[String]) -> Vec<(String, String)> {
    items
        .iter()
        .map(|s| match s.split_once('=') {
            Some((k, v)) => (k.to_string(), v.to_string()),
            None => (s.to_string(), "true".to_string()),
        })
        .collect()
}
