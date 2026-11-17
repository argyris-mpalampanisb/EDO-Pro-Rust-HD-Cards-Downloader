use anyhow::Result;
use std::path::{Path, PathBuf};

/// Card ID ranges (inclusive) that belong to custom cards.
/// Their images are never deleted by `--clean` and never overwritten by a download.
/// 77711000-77711999: "Ultimate Sacred Beasts" custom cards.
pub const DEFAULT_PROTECTED: &[(u32, u32)] = &[(77_711_000, 77_711_999)];

/// Parse a list like "77711000-77711999,88800001" into inclusive ranges.
pub fn parse_protected(spec: &str) -> Result<Vec<(u32, u32)>> {
    let mut ranges = Vec::new();
    for part in spec.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        let (lo, hi) = match part.split_once('-') {
            Some((a, b)) => (a.trim().parse::<u32>()?, b.trim().parse::<u32>()?),
            None => {
                let id = part.parse::<u32>()?;
                (id, id)
            }
        };
        if lo > hi {
            anyhow::bail!("invalid range '{}': start is greater than end", part);
        }
        ranges.push((lo, hi));
    }
    Ok(ranges)
}

pub struct Config {
    pub edopro_path: PathBuf,
    pub pics_path: PathBuf,
    /// EDOPro's main pics folder (where downloaded HD images end up after moving them)
    pub root_pics_path: PathBuf,
    pub field_pics_path: PathBuf,
    pub tracker_file: PathBuf,
    pub concurrency: usize,
    pub protected: Vec<(u32, u32)>,
}

impl Config {
    pub fn new(edopro_path: PathBuf, concurrency: usize, extra_protected: Vec<(u32, u32)>) -> Self {
        let pics_path = edopro_path.join("expansions").join("pics");
        let root_pics_path = edopro_path.join("pics");
        let field_pics_path = pics_path.join("field");
        let tracker_file = edopro_path.join("expansions").join(".hd_tracker.json");
        let mut protected = DEFAULT_PROTECTED.to_vec();
        protected.extend(extra_protected);
        Self { edopro_path, pics_path, root_pics_path, field_pics_path, tracker_file, concurrency, protected }
    }

    /// True if this card ID is a protected custom card.
    pub fn is_protected(&self, id: u32) -> bool {
        self.protected.iter().any(|&(lo, hi)| id >= lo && id <= hi)
    }

    pub fn setup_dirs(&self) -> Result<()> {
        std::fs::create_dir_all(&self.pics_path)?;
        std::fs::create_dir_all(&self.field_pics_path)?;
        Ok(())
    }

    /// Delete every downloaded image, but keep protected custom card images.
    /// Returns how many protected images were kept.
    pub fn wipe_pics(&self) -> Result<usize> {
        let mut kept = 0;
        if self.pics_path.exists() {
            kept = self.wipe_dir(&self.pics_path)?;
        }
        std::fs::create_dir_all(&self.field_pics_path)?;
        Ok(kept)
    }

    fn wipe_dir(&self, dir: &Path) -> Result<usize> {
        let mut kept = 0;
        for entry in std::fs::read_dir(dir)? {
            let path = entry?.path();
            if path.is_dir() {
                kept += self.wipe_dir(&path)?;
                if std::fs::read_dir(&path)?.next().is_none() {
                    std::fs::remove_dir(&path)?;
                }
                continue;
            }
            let id = path
                .file_stem()
                .and_then(|s| s.to_str())
                .and_then(|s| s.parse::<u32>().ok());
            if matches!(id, Some(id) if self.is_protected(id)) {
                kept += 1;
                continue;
            }
            std::fs::remove_file(&path)?;
        }
        Ok(kept)
    }

    pub fn target_path(&self, id: u32, is_field: bool) -> PathBuf {
        let base = if is_field { &self.field_pics_path } else { &self.pics_path };
        base.join(format!("{}.jpg", id))
    }
}   