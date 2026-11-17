//! Give Anime / VG / Pre-Errata / reprint cards the HD artwork of the official card they are based on.
//!
//! YGOPRODeck has no images for EDOPro's unofficial cards, but most of them are versions of an
//! official card. Matching is done with EDOPro's own card databases (`.cdb` files), in this order:
//!   1. the card's `alias` points to an official card that has an HD image,
//!   2. its name is identical to an official card's name,
//!   3. its name without a trailing "(Anime)", "(VG)", "(Manga)", "(Skill)"... matches one.
//!
//! Rush Duel cards and tokens are skipped. Only missing or low-resolution images are replaced, so
//! HD art and custom card art are never overwritten. Every copy is logged in `variant_art_log.csv`.

use crate::config::Config;
use anyhow::Result;
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

/// Images at least this wide are treated as HD (EDOPro's own images are 177 px wide).
const HD_MIN_WIDTH: u32 = 400;
const TYPE_TOKEN: i64 = 0x4000;
const SCOPE_RUSH: i64 = 0x200;

#[derive(Default)]
pub struct VariantReport {
    pub copied: usize,
    pub by_alias: usize,
    pub by_name: usize,
}

struct CardRow {
    ot: i64,
    alias: u32,
    kind: i64,
    name: String,
}

/// Width of a JPEG or PNG image, read from its header only. Returns 0 if unreadable.
pub fn image_width(path: &Path) -> u32 {
    fn read(path: &Path) -> std::io::Result<u32> {
        let mut f = File::open(path)?;
        let mut head = [0u8; 24];
        f.read_exact(&mut head)?;
        if head[..8] == *b"\x89PNG\r\n\x1a\n" {
            return Ok(u32::from_be_bytes([head[16], head[17], head[18], head[19]]));
        }
        // Walk JPEG segments until the frame header (SOF0/1/2) without reading image data
        let mut pos: u64 = 2;
        for _ in 0..64 {
            f.seek(SeekFrom::Start(pos))?;
            let mut seg = [0u8; 9];
            f.read_exact(&mut seg)?;
            if seg[0] != 0xFF {
                return Ok(0);
            }
            if matches!(seg[1], 0xC0 | 0xC1 | 0xC2) {
                return Ok(u16::from_be_bytes([seg[7], seg[8]]) as u32);
            }
            pos += 2 + u16::from_be_bytes([seg[2], seg[3]]) as u64;
        }
        Ok(0)
    }
    read(path).unwrap_or(0)
}

/// "Dark Magician (Anime)" -> Some("Dark Magician")
fn strip_suffix(name: &str) -> Option<&str> {
    let trimmed = name.trim_end();
    if !trimmed.ends_with(')') {
        return None;
    }
    let open = trimmed.rfind('(')?;
    let inner = &trimmed[open + 1..trimmed.len() - 1];
    if inner.contains('(') || inner.contains(')') {
        return None;
    }
    let base = trimmed[..open].trim_end();
    if base.is_empty() { None } else { Some(base) }
}

/// All card databases EDOPro loads: expansions/*.cdb and repositories/*/*.cdb
fn card_databases(config: &Config) -> Vec<PathBuf> {
    let mut dbs = Vec::new();
    let mut add_dir = |dir: PathBuf| {
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.extension().map_or(false, |e| e.eq_ignore_ascii_case("cdb")) {
                    dbs.push(p);
                }
            }
        }
    };
    add_dir(config.edopro_path.join("expansions"));
    if let Ok(repos) = std::fs::read_dir(config.edopro_path.join("repositories")) {
        for repo in repos.flatten() {
            if repo.path().is_dir() {
                add_dir(repo.path());
            }
        }
    }
    dbs.sort();
    dbs
}

fn load_cards(config: &Config) -> Result<HashMap<u32, CardRow>> {
    let mut cards = HashMap::new();
    for db in card_databases(config) {
        let conn = rusqlite::Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        let mut stmt = conn.prepare(
            "SELECT d.id, d.ot, d.alias, d.type, t.name FROM datas d JOIN texts t ON d.id = t.id",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, Option<String>>(4)?,
            ))
        })?;
        for row in rows {
            let (id, ot, alias, kind, name) = row?;
            let Ok(id) = u32::try_from(id) else { continue };
            let alias = u32::try_from(alias).unwrap_or(0);
            cards.insert(id, CardRow { ot, alias, kind, name: name.unwrap_or_default() });
        }
    }
    Ok(cards)
}

/// Folders checked for HD images, in EDOPro's priority order.
fn pic_dirs(config: &Config) -> [PathBuf; 2] {
    [config.pics_path.clone(), config.root_pics_path.clone()]
}

fn find_hd(dirs: &[PathBuf], existing: &[HashSet<String>], id: u32) -> Option<PathBuf> {
    let file = format!("{}.jpg", id);
    for (dir, names) in dirs.iter().zip(existing) {
        if names.contains(&file) {
            let p = dir.join(&file);
            if image_width(&p) >= HD_MIN_WIDTH {
                return Some(p);
            }
        }
    }
    None
}

pub fn apply_variant_art(config: &Config) -> Result<VariantReport> {
    let cards = load_cards(config)?;
    let dirs = pic_dirs(config);
    let existing: Vec<HashSet<String>> = dirs
        .iter()
        .map(|d| {
            std::fs::read_dir(d)
                .map(|it| it.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
                .unwrap_or_default()
        })
        .collect();

    // HD image for every card that has one
    let hd: HashMap<u32, PathBuf> = cards
        .keys()
        .filter_map(|&id| find_hd(&dirs, &existing, id).map(|p| (id, p)))
        .collect();

    // Official card per name, preferring the main artwork (alias 0)
    let mut ids: Vec<u32> = hd.keys().copied().collect();
    ids.sort_unstable();
    let mut by_name: HashMap<String, u32> = HashMap::new();
    for id in ids {
        let card = &cards[&id];
        let key = card.name.to_lowercase();
        let replace = match by_name.get(&key) {
            Some(&prev) => card.alias == 0 && cards[&prev].alias != 0,
            None => true,
        };
        if replace {
            by_name.insert(key, id);
        }
    }

    let mut targets: Vec<u32> = cards.keys().copied().collect();
    targets.sort_unstable();

    let mut report = VariantReport::default();
    let mut logs: HashMap<PathBuf, File> = HashMap::new();

    for id in targets {
        let card = &cards[&id];
        if hd.contains_key(&id)
            || card.kind & TYPE_TOKEN != 0
            || card.ot & SCOPE_RUSH != 0
            || config.is_protected(id)
        {
            continue;
        }

        let name = card.name.to_lowercase();
        let (source, by_alias) = if card.alias != 0 && hd.contains_key(&card.alias) {
            (card.alias, true)
        } else if let Some(&src) = by_name.get(&name) {
            (src, false)
        } else if let Some(&src) = strip_suffix(&name).and_then(|base| by_name.get(base)) {
            (src, false)
        } else {
            continue;
        };
        if source == id {
            continue;
        }

        // Write next to the source image, so the copy lives wherever the HD art lives
        let src_path = &hd[&source];
        let dir = src_path.parent().unwrap_or(Path::new("."));
        std::fs::copy(src_path, dir.join(format!("{}.jpg", id)))?;

        if !logs.contains_key(dir) {
            let log_path = dir.join("variant_art_log.csv");
            let is_new = !log_path.exists();
            let mut f = std::fs::OpenOptions::new().create(true).append(true).open(&log_path)?;
            if is_new {
                writeln!(f, "card_id,copied_from,match,name")?;
            }
            logs.insert(dir.to_path_buf(), f);
        }
        let log = logs.get_mut(dir).expect("log file was just opened");
        let how = if by_alias { "alias" } else { "name" };
        writeln!(log, "{},{},{},\"{}\"", id, source, how, card.name.replace('"', "\"\""))?;

        report.copied += 1;
        if by_alias { report.by_alias += 1 } else { report.by_name += 1 }
    }

    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::strip_suffix;

    #[test]
    fn strips_trailing_tag() {
        assert_eq!(strip_suffix("Dark Magician (Anime)"), Some("Dark Magician"));
        assert_eq!(strip_suffix("Puppet Ritual (VG) "), Some("Puppet Ritual"));
        assert_eq!(strip_suffix("Dark Magician"), None);
        assert_eq!(strip_suffix("(Anime)"), None);
    }
}
