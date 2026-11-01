use crate::api::DownloadItem;
use crate::config::Config;
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Serialize, Deserialize, Default)]
struct TrackerData {
    cards: HashSet<u32>,
    fields: HashSet<u32>,
}

pub struct Tracker {
    data: TrackerData,
    path: std::path::PathBuf,
}

impl Tracker {
    pub fn new(config: &Config) -> Result<Self> {
        let path = config.tracker_file.clone();
        let data = if path.exists() {
            let content = std::fs::read_to_string(&path)?;
            serde_json::from_str(&content).unwrap_or_default()
        } else {
            TrackerData::default()
        };
        Ok(Self { data, path })
    }

    pub fn is_downloaded(&self, item: &DownloadItem) -> bool {
        if item.is_field {
            self.data.fields.contains(&item.id)
        } else {
            self.data.cards.contains(&item.id)
        }
    }

    pub fn mark_downloaded(&mut self, item: &DownloadItem) {
        if item.is_field {
            self.data.fields.insert(item.id);
        } else {
            self.data.cards.insert(item.id);
        }
    }

    pub fn save(&self) -> Result<()> {
        let content = serde_json::to_string_pretty(&self.data)?;
        std::fs::write(&self.path, content)?;
        Ok(())
    }
}   