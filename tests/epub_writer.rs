//! EPUB writer integration tests.

use std::io::Cursor;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn binary_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("target");
    p.push(if cfg!(debug_assertions) { "debug" } else { "release" });
    p.push("minipandoc");
    p
}

fn fixtures_dir() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.extend(["tests", "fixtures", "epub"]);
    p
}

fn run_epub(fixture: &str, extra_args: &[&str]) -> Vec<u8> {
    let input = fixtures_dir().join(fixture);
    let mut cmd = Command::new(binary_path());
    cmd.args(["-f", "native", "-t", "epub"]);
    cmd.args(extra_args);
    cmd.arg(&input);
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    let out = cmd.output().expect("spawn minipandoc");
    assert!(
        out.status.success(),
        "minipandoc failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out.stdout
}

#[test]
fn epub_is_valid_zip() {
    let bytes = run_epub("basic.native", &[]);
    // ZIP files start with PK magic bytes
    assert!(bytes.len() > 4, "output too small");
    assert_eq!(&bytes[0..2], b"PK", "not a ZIP file");
    // Should be parseable as a ZIP
    let reader = Cursor::new(&bytes);
    let archive = zip::ZipArchive::new(reader).expect("parse ZIP");
    assert!(archive.len() > 0, "empty archive");
}

#[test]
fn epub_mimetype_entry() {
    let bytes = run_epub("basic.native", &[]);
    let reader = Cursor::new(&bytes);
    let mut archive = zip::ZipArchive::new(reader).expect("parse ZIP");
    // mimetype must be the first entry
    let first = archive.by_index(0).expect("first entry");
    assert_eq!(first.name(), "mimetype");
    assert_eq!(first.compression(), zip::CompressionMethod::Stored);
    drop(first);
    let mut mt = archive.by_name("mimetype").expect("mimetype entry");
    let mut content = String::new();
    std::io::Read::read_to_string(&mut mt, &mut content).unwrap();
    assert_eq!(content, "application/epub+zip");
}

#[test]
fn epub_has_required_files() {
    let bytes = run_epub("basic.native", &[]);
    let reader = Cursor::new(&bytes);
    let archive = zip::ZipArchive::new(reader).expect("parse ZIP");
    let names: Vec<String> = (0..archive.len())
        .map(|i| archive.name_for_index(i).unwrap().to_string())
        .collect();
    assert!(names.contains(&"META-INF/container.xml".to_string()));
    assert!(names.contains(&"EPUB/content.opf".to_string()));
    assert!(names.contains(&"EPUB/nav.xhtml".to_string()));
    assert!(names.contains(&"EPUB/styles/stylesheet.css".to_string()));
    assert!(names.contains(&"EPUB/text/chapter-1.xhtml".to_string()));
}

#[test]
fn epub_content_opf_has_metadata() {
    let bytes = run_epub("basic.native", &[]);
    let reader = Cursor::new(&bytes);
    let mut archive = zip::ZipArchive::new(reader).expect("parse ZIP");
    let mut opf = archive.by_name("EPUB/content.opf").expect("content.opf");
    let mut content = String::new();
    std::io::Read::read_to_string(&mut opf, &mut content).unwrap();
    assert!(content.contains("<dc:title>Basic Test</dc:title>"), "title missing");
    assert!(content.contains("<dc:creator>Author</dc:creator>"), "author missing");
    assert!(content.contains("<dc:language>en</dc:language>"), "language missing");
    assert!(content.contains("urn:uuid:"), "identifier missing");
}

#[test]
fn epub_chapter_splitting() {
    let bytes = run_epub("multi_chapter.native", &[]);
    let reader = Cursor::new(&bytes);
    let archive = zip::ZipArchive::new(reader).expect("parse ZIP");
    let names: Vec<String> = (0..archive.len())
        .map(|i| archive.name_for_index(i).unwrap().to_string())
        .collect();
    assert!(names.contains(&"EPUB/text/chapter-1.xhtml".to_string()));
    assert!(names.contains(&"EPUB/text/chapter-2.xhtml".to_string()));
    assert!(names.contains(&"EPUB/text/chapter-3.xhtml".to_string()));
    // Should not have a 4th chapter
    assert!(!names.contains(&"EPUB/text/chapter-4.xhtml".to_string()));
}

#[test]
fn epub_chapter_content_is_xhtml() {
    let bytes = run_epub("basic.native", &[]);
    let reader = Cursor::new(&bytes);
    let mut archive = zip::ZipArchive::new(reader).expect("parse ZIP");
    let mut ch = archive.by_name("EPUB/text/chapter-1.xhtml").expect("chapter-1");
    let mut content = String::new();
    std::io::Read::read_to_string(&mut ch, &mut content).unwrap();
    assert!(content.contains("<?xml version=\"1.0\""), "missing XML declaration");
    assert!(content.contains("xmlns=\"http://www.w3.org/1999/xhtml\""), "missing XHTML namespace");
    assert!(content.contains("<title>Introduction</title>"), "missing title");
    assert!(content.contains("simple test document"), "missing body content");
}

#[test]
fn epub_nav_has_toc() {
    let bytes = run_epub("multi_chapter.native", &[]);
    let reader = Cursor::new(&bytes);
    let mut archive = zip::ZipArchive::new(reader).expect("parse ZIP");
    let mut nav = archive.by_name("EPUB/nav.xhtml").expect("nav.xhtml");
    let mut content = String::new();
    std::io::Read::read_to_string(&mut nav, &mut content).unwrap();
    assert!(content.contains("epub:type=\"toc\""), "missing toc type");
    assert!(content.contains("First Chapter"), "missing first chapter title");
    assert!(content.contains("Second Chapter"), "missing second chapter title");
    assert!(content.contains("Third Chapter"), "missing third chapter title");
}

#[test]
fn epub_metadata_override() {
    let bytes = run_epub(
        "basic.native",
        &["--metadata", "title=Custom Title", "--metadata", "author=Custom Author"],
    );
    let reader = Cursor::new(&bytes);
    let mut archive = zip::ZipArchive::new(reader).expect("parse ZIP");
    let mut opf = archive.by_name("EPUB/content.opf").expect("content.opf");
    let mut content = String::new();
    std::io::Read::read_to_string(&mut opf, &mut content).unwrap();
    assert!(content.contains("<dc:title>Custom Title</dc:title>"), "custom title missing");
    assert!(content.contains("<dc:creator>Custom Author</dc:creator>"), "custom author missing");
}

#[test]
fn epub_container_xml() {
    let bytes = run_epub("basic.native", &[]);
    let reader = Cursor::new(&bytes);
    let mut archive = zip::ZipArchive::new(reader).expect("parse ZIP");
    let mut c = archive.by_name("META-INF/container.xml").expect("container.xml");
    let mut content = String::new();
    std::io::Read::read_to_string(&mut c, &mut content).unwrap();
    assert!(content.contains("full-path=\"EPUB/content.opf\""), "missing rootfile");
}
