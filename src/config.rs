use anyhow::Result;
use std::path::PathBuf;

pub struct Config {
    pub edopro_path: PathBuf,
    pub pics_path: PathBuf,
    pub field_pics_path: PathBuf,
    pub tracker_file: PathBuf,
    pub concurrency: usize,
}

impl Config {
    pub fn new(edopro_path: PathBuf, concurrency: usize) -> Self {
        let pics_path = edopro_path.join("expansions").join("pics");
        let field_pics_path = pics_path.join("field");
        let tracker_file = edopro_path.join("expansions").join(".hd_tracker.json");
        Self { edopro_path, pics_path, field_pics_path, tracker_file, concurrency }
    }

    pub fn setup_dirs(&self) -> Result<()> {
        std::fs::create_dir_all(&self.pics_path)?;
        std::fs::create_dir_all(&self.field_pics_path)?;
        Ok(())
    }

    pub fn wipe_pics(&self) -> Result<()> {
        if self.pics_path.exists() {
            std::fs::remove_dir_all(&self.pics_path)?;
        }
        std::fs::create_dir_all(&self.field_pics_path)?;
        Ok(())
    }

    pub fn target_path(&self, id: u32, is_field: bool) -> PathBuf {
        let base = if is_field { &self.field_pics_path } else { &self.pics_path };
        base.join(format!("{}.jpg", id))
    }
}   