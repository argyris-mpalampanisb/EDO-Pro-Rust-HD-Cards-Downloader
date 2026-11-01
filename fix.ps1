# Run this from your project root (where Cargo.toml is)

# Create src dir if needed
New-Item -ItemType Directory -Force -Path src | Out-Null

# --- src/main.rs ---
@'
mod api;
mod config;
mod downloader;
mod tracker;

use anyhow::Result;
use clap::Parser;
use std::io::Write;
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "edopro-hd", about = "HD card image downloader for EDOPro")]
struct Cli {
    /// Path to EDOPro root folder
    #[arg(short, long, default_value = ".")]
    edopro_path: PathBuf,

    /// Download all cards
    #[arg(short = 'a', long)]
    all_cards: bool,

    /// Download all field spell images
    #[arg(long)]
    all_fields: bool,

    /// Download all tokens
    #[arg(long)]
    all_tokens: bool,

    /// Force re-download even if already cached
    #[arg(short, long)]
    force: bool,

    /// Number of concurrent downloads
    #[arg(short, long, default_value_t = 10)]
    concurrency: usize,

    /// Deck file to download
    #[arg(short, long)]
    deck: Option<PathBuf>,

    /// Specific card IDs to download (comma-separated)
    #[arg(short, long)]
    ids: Option<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let config = config::Config::new(cli.edopro_path, cli.concurrency);

    config.setup_dirs()?;
    let mut tracker = tracker::Tracker::new(&config)?;

    if cli.all_cards || cli.all_fields || cli.all_tokens || cli.deck.is_some() || cli.ids.is_some() {
        let items: Vec<api::DownloadItem> = collect_items(&cli, &config).await?;

        let to_download: Vec<api::DownloadItem> = items
            .iter()
            .filter(|item| cli.force || !tracker.is_downloaded(item))
            .cloned()
            .collect();

        println!("Found {} new images to download.", to_download.len());

        if to_download.is_empty() {
            println!("Everything is up to date!");
            return Ok(());
        }

        let result = downloader::download_all(&config, &to_download).await?;

        for item in &to_download {
            tracker.mark_downloaded(item);
        }
        tracker.save()?;

        println!("\nDone: {} succeeded, {} failed.", result.succeeded, result.failed);
    } else {
        interactive_mode(&config, &mut tracker, cli.force).await?;
    }

    Ok(())
}

async fn collect_items(cli: &Cli, _config: &config::Config) -> Result<Vec<api::DownloadItem>> {
    let mut items = Vec::new();

    if cli.all_cards || cli.all_tokens {
        let ids: Vec<u32> = api::get_all_card_ids().await?;
        for id in ids {
            if id != 0 {
                items.push(api::DownloadItem { id, is_field: false });
            }
        }
    }

    if cli.all_fields {
        let ids: Vec<u32> = api::get_all_field_ids().await?;
        for id in ids {
            if id != 0 {
                items.push(api::DownloadItem { id, is_field: true });
            }
        }
    }

    if let Some(deck_path) = &cli.deck {
        items.extend(api::parse_deck(deck_path)?);
    }

    if let Some(ids_str) = &cli.ids {
        for s in ids_str.split(',') {
            if let Ok(id) = s.trim().parse::<u32>() {
                items.push(api::DownloadItem { id, is_field: false });
            }
        }
    }

    Ok(items)
}

async fn interactive_mode(
    config: &config::Config,
    tracker: &mut tracker::Tracker,
    force: bool,
) -> Result<()> {
    println!("=== EDOPro HD Downloader (interactive) ===");
    println!("Commands: /allcards, /allfields, /alltokens, /deck <name>, /ids <123,456>, /quit");

    loop {
        print!("\n> ");
        std::io::stdout().flush()?;

        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
        let input = input.trim();

        if input.is_empty() { continue; }
        if input == "/quit" || input == "/exit" { break; }

        let items: Vec<api::DownloadItem> = if input == "/allcards" {
            let ids: Vec<u32> = api::get_all_card_ids().await?;
            ids.into_iter().filter(|&id| id != 0).map(|id| api::DownloadItem { id, is_field: false }).collect()
        } else if input == "/allfields" {
            let ids: Vec<u32> = api::get_all_field_ids().await?;
            ids.into_iter().filter(|&id| id != 0).map(|id| api::DownloadItem { id, is_field: true }).collect()
        } else if input == "/alltokens" {
            let ids: Vec<u32> = api::get_all_token_ids().await?;
            ids.into_iter().filter(|&id| id != 0).map(|id| api::DownloadItem { id, is_field: false }).collect()
        } else if input.starts_with("/deck ") {
            let name = input[6..].trim();
            let path = config.edopro_path.join("expansions").join("decks").join(format!("{}.ydk", name));
            if !path.exists() {
                eprintln!("Deck not found: {}", path.display());
                continue;
            }
            api::parse_deck(&path)?
        } else if input.starts_with("/ids ") {
            input[5..].split(',').filter_map(|s| s.trim().parse::<u32>().ok())
                .map(|id| api::DownloadItem { id, is_field: false }).collect()
        } else {
            match api::search_cards(input).await {
                Ok(cards) => cards,
                Err(e) => {
                    eprintln!("Card or command not found: {}", e);
                    continue;
                }
            }
        };

        if items.is_empty() {
            println!("No cards found.");
            continue;
        }

        let to_download: Vec<api::DownloadItem> = items
            .iter()
            .filter(|item| force || !tracker.is_downloaded(item))
            .cloned()
            .collect();

        if to_download.is_empty() {
            println!("All already downloaded.");
            continue;
        }

        println!("Downloading {} cards...", to_download.len());
        let result = downloader::download_all(config, &to_download).await?;

        for item in &to_download {
            tracker.mark_downloaded(item);
        }
        tracker.save()?;

        println!("Done: {} succeeded, {} failed.", result.succeeded, result.failed);
    }

    println!("Bye!");
    Ok(())
}
'@ | Set-Content -Path "src\main.rs" -Encoding UTF8

# --- src/api.rs ---
@'
use anyhow::{Context, Result};
use serde::Deserialize;
use std::path::Path;

const API_BASE: &str = "https://db.ygoprodeck.com/api/v7";

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
    id: u32,
    #[serde(rename = "type")]
    card_type: String,
}

pub async fn get_all_card_ids() -> Result<Vec<u32>> {
    let resp = reqwest::get(format!("{}/cardinfo.php?format=tcg", API_BASE))
        .await
        .context("Failed to fetch card list")?;
    let body: ApiResponse = resp.json().await?;
    Ok(body.data.into_iter()
        .filter(|c| !c.card_type.contains("Field") && !c.card_type.contains("Token"))
        .map(|c| c.id)
        .collect())
}

pub async fn get_all_field_ids() -> Result<Vec<u32>> {
    let resp = reqwest::get(format!("{}/cardinfo.php?format=tcg", API_BASE))
        .await
        .context("Failed to fetch field list")?;
    let body: ApiResponse = resp.json().await?;
    Ok(body.data.into_iter()
        .filter(|c| c.card_type.contains("Field"))
        .map(|c| c.id)
        .collect())
}

pub async fn get_all_token_ids() -> Result<Vec<u32>> {
    let resp = reqwest::get(format!("{}/cardinfo.php?format=tcg", API_BASE))
        .await
        .context("Failed to fetch token list")?;
    let body: ApiResponse = resp.json().await?;
    Ok(body.data.into_iter()
        .filter(|c| c.card_type.contains("Token"))
        .map(|c| c.id)
        .collect())
}

pub async fn search_cards(name: &str) -> Result<Vec<DownloadItem>> {
    let url = format!("{}/cardinfo.php?fname={}", API_BASE, urlencoding::encode(name));
    let resp = reqwest::get(&url)
        .await
        .context("Failed to search cards")?;
    let body: ApiResponse = resp.json().await?;
    Ok(body.data.into_iter()
        .map(|c| DownloadItem { id: c.id, is_field: c.card_type.contains("Field") })
        .collect())
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
'@ | Set-Content -Path "src\api.rs" -Encoding UTF8

# --- src/config.rs ---
@'
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

    pub fn target_path(&self, id: u32, is_field: bool) -> PathBuf {
        let base = if is_field { &self.field_pics_path } else { &self.pics_path };
        base.join(format!("{}.jpg", id))
    }
}
'@ | Set-Content -Path "src\config.rs" -Encoding UTF8

# --- src/downloader.rs ---
@'
use crate::api::DownloadItem;
use crate::config::Config;
use anyhow::Result;
use futures::stream::{self, StreamExt};
use std::sync::atomic::{AtomicUsize, Ordering};

const IMAGE_URL: &str = "https://images.ygoprodeck.com/images/cards/{}.jpg";

pub struct DownloadResult {
    pub succeeded: usize,
    pub failed: usize,
}

pub async fn download_all(config: &Config, items: &[DownloadItem]) -> Result<DownloadResult> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;

    let succeeded = AtomicUsize::new(0);
    let failed = AtomicUsize::new(0);
    let total = items.len();
    let done = AtomicUsize::new(0);
    let semaphore = tokio::sync::Semaphore::new(config.concurrency);

    let _ = stream::iter(items.iter())
        .map(|item| {
            let client = &client;
            let config = &config;
            let semaphore = &semaphore;
            let succeeded = &succeeded;
            let failed = &failed;
            let done = &done;
            let total = total;

            async move {
                let _permit = semaphore.acquire_owned().await.unwrap();
                let url = format!(IMAGE_URL, item.id);
                let target = config.target_path(item.id, item.is_field);

                let result: Result<()> = async {
                    let resp = client.get(&url).send().await
                        .map_err(|e| anyhow::anyhow!("Request error: {}", e))?;
                    if !resp.status().is_success() {
                        return Err(anyhow::anyhow!("HTTP {}", resp.status()));
                    }
                    let bytes = resp.bytes().await
                        .map_err(|e| anyhow::anyhow!("Read error: {}", e))?;
                    tokio::fs::write(&target, &bytes).await
                        .map_err(|e| anyhow::anyhow!("Write error: {}", e))?;
                    Ok(())
                }.await;

                match result {
                    Ok(()) => { succeeded.fetch_add(1, Ordering::Relaxed); }
                    Err(e) => {
                        eprintln!("Failed {}: {}", item.id, e);
                        failed.fetch_add(1, Ordering::Relaxed);
                    }
                }

                let n = done.fetch_add(1, Ordering::Relaxed) + 1;
                if n % 50 == 0 || n == total {
                    print!("\rProgress: {}/{} ({}%)", n, total, (n * 100) / total);
                    std::io::Write::flush(&mut std::io::stdout()).ok();
                }
            }
        })
        .buffer_unordered(config.concurrency)
        .collect::<Vec<_>>()
        .await;

    println!();

    Ok(DownloadResult {
        succeeded: succeeded.load(Ordering::Relaxed),
        failed: failed.load(Ordering::Relaxed),
    })
}
'@ | Set-Content -Path "src\downloader.rs" -Encoding UTF8

# --- src/tracker.rs ---
@'
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
'@ | Set-Content -Path "src\tracker.rs" -Encoding UTF8

# --- Cargo.toml ---
@'
[package]
name = "edopro-hd"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { version = "1", features = ["full"] }
reqwest = { version = "0.12", features = ["json"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
clap = { version = "4", features = ["derive"] }
anyhow = "1"
futures = "0.3"
urlencoding = "2"
'@ | Set-Content -Path "Cargo.toml" -Encoding UTF8

Write-Host "All files written. Now run: cargo build --release" -ForegroundColor Green   