//! One Markdown file per item:
//!
//! ```text
//! ---
//! title: "Some title"
//! created: 2026-10-13T15:42:07-03:00
//! ---
//! the captured text
//! ```
//!
//! Files without front matter (e.g. dropped in by hand) are still listed:
//! the whole file is the body and the file's mtime stands in for `created`.

use chrono::{DateTime, Local, SecondsFormat};
use serde::Serialize;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

#[derive(Debug, Serialize)]
pub struct Item {
    pub id: String,
    pub title: String,
    pub created: String,
    pub body: String,
}

pub fn dir() -> PathBuf {
    if let Some(d) = std::env::var_os("SNIPPETS_DIR").filter(|d| !d.is_empty()) {
        return PathBuf::from(d);
    }
    home().join("Documents/snippets")
}

/// Touched after every change so open panels can reload without polling.
pub fn change_stamp() -> PathBuf {
    let state = std::env::var_os("XDG_STATE_HOME")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".local/state"));
    state.join("snippets/changed")
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| "/".into()))
}

/// Ids are file stems. Reject anything that could escape the directory.
pub fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && !id.starts_with('.')
        && id.len() <= 200
        && id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

fn path_for(id: &str) -> PathBuf {
    dir().join(format!("{id}.md"))
}

fn new_id(now: &DateTime<Local>) -> String {
    let base = now.format("%Y%m%d-%H%M%S").to_string();
    let salt = now.timestamp_subsec_nanos() & 0xffff;
    let mut id = format!("{base}-{salt:04x}");
    let mut n = 1;
    while path_for(&id).exists() {
        id = format!("{base}-{salt:04x}-{n}");
        n += 1;
    }
    id
}

fn parse(id: String, text: &str, mtime: Option<DateTime<Local>>) -> Item {
    let fallback_created = mtime
        .map(|t| t.to_rfc3339_opts(SecondsFormat::Secs, false))
        .unwrap_or_default();

    let front = text
        .strip_prefix("---\n")
        .and_then(|rest| rest.find("\n---\n").map(|end| (&rest[..end], &rest[end + 5..])))
        .or_else(|| {
            // Front matter with an empty body: file ends right after the closing fence.
            text.strip_prefix("---\n")
                .and_then(|rest| rest.strip_suffix("\n---").map(|fm| (fm, "")))
        });

    let Some((front, body)) = front else {
        return Item { id, title: String::new(), created: fallback_created, body: text.to_string() };
    };

    let mut title = String::new();
    let mut created = String::new();
    for line in front.lines() {
        let Some((key, value)) = line.split_once(':') else { continue };
        let value = value.trim();
        match key.trim() {
            "title" => title = unquote(value),
            "created" => created = unquote(value),
            _ => {}
        }
    }
    if created.is_empty() {
        created = fallback_created;
    }
    Item { id, title, created, body: body.to_string() }
}

fn unquote(value: &str) -> String {
    if value.starts_with('"') {
        if let Ok(s) = serde_json::from_str::<String>(value) {
            return s;
        }
    }
    value.to_string()
}

fn render(item: &Item) -> String {
    // A JSON string is a valid YAML double-quoted scalar, so this stays
    // readable by any front-matter parser.
    let title = serde_json::to_string(&item.title).unwrap_or_else(|_| "\"\"".into());
    format!("---\ntitle: {title}\ncreated: {}\n---\n{}", item.created, item.body)
}

pub fn list() -> io::Result<Vec<Item>> {
    let entries = match fs::read_dir(dir()) {
        Ok(entries) => entries,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e),
    };

    let mut items = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        let Some(id) = path.file_stem().and_then(|s| s.to_str()).filter(|s| valid_id(s)) else {
            continue;
        };
        let Ok(text) = fs::read_to_string(&path) else { continue };
        let mtime = entry.metadata().and_then(|m| m.modified()).ok().map(DateTime::<Local>::from);
        items.push(parse(id.to_string(), &text, mtime));
    }
    // RFC 3339 timestamps with the same offset sort lexically; parse to be
    // safe across DST/timezone changes.
    items.sort_by_key(|i| std::cmp::Reverse(DateTime::parse_from_rfc3339(&i.created).ok()));
    Ok(items)
}

/// Create (no id) or update an item. Returns the item's id.
pub fn save(id: Option<&str>, title: &str, body: &str) -> io::Result<String> {
    let now = Local::now();
    let (id, created) = match id.filter(|i| !i.is_empty()) {
        Some(id) => {
            if !valid_id(id) {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, format!("invalid id: {id}")));
            }
            let created = fs::read_to_string(path_for(id))
                .ok()
                .map(|t| parse(id.to_string(), &t, None).created)
                .filter(|c| !c.is_empty())
                .unwrap_or_else(|| now.to_rfc3339_opts(SecondsFormat::Secs, false));
            (id.to_string(), created)
        }
        None => {
            fs::create_dir_all(dir())?;
            (new_id(&now), now.to_rfc3339_opts(SecondsFormat::Secs, false))
        }
    };

    let item = Item {
        id: id.clone(),
        title: title.trim().replace(['\n', '\r'], " "),
        created,
        body: body.to_string(),
    };
    fs::create_dir_all(dir())?;
    write_atomic(&path_for(&id), render(&item).as_bytes())?;
    touch_change_stamp();
    Ok(id)
}

pub fn delete(id: &str) -> io::Result<()> {
    if !valid_id(id) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, format!("invalid id: {id}")));
    }
    match fs::remove_file(path_for(id)) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    touch_change_stamp();
    Ok(())
}

fn write_atomic(path: &Path, data: &[u8]) -> io::Result<()> {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("item");
    let tmp = path.with_file_name(format!(".{name}.tmp"));
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path)
}

fn touch_change_stamp() {
    let stamp = change_stamp();
    if let Some(parent) = stamp.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(stamp, Local::now().to_rfc3339());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_front_matter() {
        let item = Item {
            id: "a".into(),
            title: "Hello: \"world\"".into(),
            created: "2026-10-13T15:42:07-03:00".into(),
            body: "line 1\n---\nline 3\n".into(),
        };
        let parsed = parse("a".into(), &render(&item), None);
        assert_eq!(parsed.title, item.title);
        assert_eq!(parsed.created, item.created);
        assert_eq!(parsed.body, item.body);
    }

    #[test]
    fn empty_body_round_trips() {
        let item = Item { id: "a".into(), title: "t".into(), created: "c".into(), body: String::new() };
        let parsed = parse("a".into(), &render(&item), None);
        assert_eq!(parsed.title, "t");
        assert_eq!(parsed.body, "");
    }

    #[test]
    fn plain_file_is_all_body() {
        let parsed = parse("a".into(), "just text\n", None);
        assert_eq!(parsed.title, "");
        assert_eq!(parsed.body, "just text\n");
    }

    #[test]
    fn rejects_path_ids() {
        assert!(!valid_id("../x"));
        assert!(!valid_id(".hidden"));
        assert!(!valid_id("a/b"));
        assert!(valid_id("20261013-154207-0a1b"));
    }
}
