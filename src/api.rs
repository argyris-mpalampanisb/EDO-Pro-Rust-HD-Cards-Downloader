use anyhow::{Context, Result};
use serde::Deserialize;
use std::path::Path;

const API_BASE: &str = "https://db.ygoprodeck.com/api/v7/cardinfo.php";

#[derive(Debug, Clone)]
pub struct DownloadItem {
    pub id: u32,
    pub is_field: bool,
}

#[derive(Deserialize)]
struct ApiResponse {
    data: Vec<CardData>,
}

#[derive(Deserialize)]
struct CardData {
    #[serde(rename = "card_images")]
    card_images: Vec<CardImage>,
}

#[derive(Deserialize)]
struct CardImage {
    id: u32,
}

/// Get ALL image IDs from the full card list (no filter)
pub async fn get_all_card_ids() -> Result<Vec<u32>> {
    let resp = reqwest::get(API_BASE)
        .await
        .context("Failed to fetch card list")?;
    let body: ApiResponse = resp.json().await?;
    let mut ids = Vec::new();
    for card in &body.data {
        for img in &card.card_images {
            if img.id != 0 {
                ids.push(img.id);
            }
        }
    }
    ids.sort();
    ids.dedup();
    Ok(ids)
}

/// Get field spell image IDs
pub async fn get_all_field_ids() -> Result<Vec<u32>> {
    let url = format!("{}?type=spell card&race=field", API_BASE);
    let resp = reqwest::get(&url)
        .await
        .context("Failed to fetch field list")?;
    let body: ApiResponse = resp.json().await?;
    let mut ids = Vec::new();
    for card in &body.data {
        for img in &card.card_images {
            if img.id != 0 {
                ids.push(img.id);
            }
        }
    }
    ids.sort();
    ids.dedup();
    Ok(ids)
}

pub async fn search_cards(name: &str) -> Result<Vec<DownloadItem>> {
    let url = format!("{}?fname={}", API_BASE, urlencoding::encode(name));
    let resp = reqwest::get(&url)
        .await
        .context("Failed to search cards")?;
    let body: ApiResponse = resp.json().await?;
    let mut items = Vec::new();
    for card in &body.data {
        for img in &card.card_images {
            if img.id != 0 {
                items.push(DownloadItem { id: img.id, is_field: false });
            }
        }
    }
    Ok(items)
}

pub fn parse_deck(path: &Path) -> Result<Vec<DownloadItem>> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("Failed to read deck file: {}", path.display()))?;

    let mut items = Vec::new();
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        let id_str = line.split_whitespace().next().unwrap_or(line);
        if let Ok(id) = id_str.parse::<u32>() {
            if id != 0 {
                items.push(DownloadItem { id, is_field: false });
            }
        }
    }
    Ok(items)
}   