# Run this from your project root (where Cargo.toml is)

# Rewrites every source file with the latest version (protected custom cards, variant art and Rush Duel art included)

# Create src dir if needed
New-Item -ItemType Directory -Force -Path src | Out-Null

# --- src/main.rs ---
@'
mod api;
mod config;
mod downloader;
mod tracker;
mod variants;

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

    /// Force re-download even if already cached
    #[arg(short, long)]
    force: bool,

    /// Clean re-download: wipe the pics folder and download everything from scratch
    #[arg(long)]
    clean: bool,

    /// Number of concurrent downloads
    #[arg(short, long, default_value_t = 100)]
    concurrency: usize,

    /// Deck file to download
    #[arg(short, long)]
    deck: Option<PathBuf>,

    /// Specific card IDs to download (comma-separated)
    #[arg(short, long)]
    ids: Option<String>,

    /// Extra custom card IDs/ranges to protect from --clean and downloads,
    /// e.g. "88800000-88800999,12345678" (77711000-77711999 is always protected)
    #[arg(short, long)]
    protect: Option<String>,

    /// Give Anime/VG/Pre-Errata/reprint cards the HD art of their official card
    /// (runs automatically after --all-cards and --clean)
    #[arg(long)]
    variants: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let extra_protected = match &cli.protect {
        Some(spec) => config::parse_protected(spec)?,
        None => Vec::new(),
    };
    let config = config::Config::new(cli.edopro_path.clone(), cli.concurrency, extra_protected);

    if cli.clean {
        println!("Wiping {} ...", config.pics_path.display());
        let kept = config.wipe_pics()?;
        println!("Done ({} custom card images kept). Starting fresh download.\n", kept);

        let mut tracker = tracker::Tracker::new(&config)?;
        let items = collect_all(&config).await?;
        println!("Found {} images to download.", items.len());

        let result = downloader::download_all(&config, &items).await?;

        for item in &items {
            tracker.mark_downloaded(item);
        }
        tracker.save()?;

        println!("\nDone: {} succeeded, {} failed.", result.succeeded, result.failed);
        run_variants(&config);
        return Ok(());
    }

    config.setup_dirs()?;

    if cli.variants && !(cli.all_cards || cli.all_fields || cli.deck.is_some() || cli.ids.is_some()) {
        run_variants(&config);
        return Ok(());
    }
    let mut tracker = tracker::Tracker::new(&config)?;

    if cli.all_cards || cli.all_fields || cli.deck.is_some() || cli.ids.is_some() {
        let items: Vec<api::DownloadItem> = if cli.all_cards || cli.all_fields {
            collect_all(&config).await?
        } else {
            collect_from_args(&cli)?
        };

        let to_download: Vec<api::DownloadItem> = items
            .iter()
            .filter(|item| cli.force || !tracker.is_downloaded(item))
            .cloned()
            .collect();

        println!("Found {} new images to download.", to_download.len());

        if to_download.is_empty() {
            println!("Everything is up to date!");
            if cli.all_cards || cli.variants {
                run_variants(&config);
            }
            return Ok(());
        }

        let result = downloader::download_all(&config, &to_download).await?;

        for item in &to_download {
            tracker.mark_downloaded(item);
        }
        tracker.save()?;

        println!("\nDone: {} succeeded, {} failed.", result.succeeded, result.failed);
        if cli.all_cards || cli.variants {
            run_variants(&config);
        }
    } else {
        interactive_mode(&config, &mut tracker, cli.force).await?;
    }

    Ok(())
}

/// Collect all card images (OCG/TCG + Rush Duel) + field images
async fn collect_all(config: &config::Config) -> Result<Vec<api::DownloadItem>> {
    let mut items = Vec::new();

    let card_ids: Vec<u32> = api::get_all_card_ids().await?;
    for id in card_ids {
        items.push(api::DownloadItem { id, is_field: false });
    }
    items.extend(rush_items(config));

    let field_ids: Vec<u32> = api::get_all_field_ids().await?;
    for id in field_ids {
        items.push(api::DownloadItem { id, is_field: true });
    }

    Ok(items)
}

/// Rush Duel cards, taken from EDOPro's own databases (YGOPRODeck's API doesn't list them)
fn rush_items(config: &config::Config) -> Vec<api::DownloadItem> {
    match variants::local_rush_ids(config) {
        Ok(ids) => {
            println!("Rush Duel: {} cards found in EDOPro's databases.", ids.len());
            ids.into_iter().map(|id| api::DownloadItem { id, is_field: false }).collect()
        }
        Err(e) => {
            eprintln!("Warning: skipping Rush Duel images ({:#})", e);
            Vec::new()
        }
    }
}

fn collect_from_args(cli: &Cli) -> Result<Vec<api::DownloadItem>> {
    let mut items = Vec::new();

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
    println!("Commands: /allcards, /allfields, /deck <name>, /ids <123,456>, /variants, /clean, /quit");

    loop {
        print!("\n> ");
        std::io::stdout().flush()?;

        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
        let input = input.trim();

        if input.is_empty() { continue; }
        if input == "/quit" || input == "/exit" { break; }

        if input == "/clean" {
            println!("Wiping {} ...", config.pics_path.display());
            let kept = config.wipe_pics()?;
            println!("Done ({} custom card images kept). Starting fresh download.\n", kept);

            let items = collect_all(config).await?;
            println!("Found {} images to download.", items.len());
            let result = downloader::download_all(config, &items).await?;

            for item in &items {
                tracker.mark_downloaded(item);
            }
            tracker.save()?;

            println!("Done: {} succeeded, {} failed.", result.succeeded, result.failed);
            run_variants(config);
            continue;
        }

        if input == "/variants" {
            run_variants(config);
            continue;
        }

        let items: Vec<api::DownloadItem> = if input == "/allcards" {
            let ids: Vec<u32> = api::get_all_card_ids().await?;
            let mut items: Vec<api::DownloadItem> =
                ids.into_iter().map(|id| api::DownloadItem { id, is_field: false }).collect();
            items.extend(rush_items(config));
            items
        } else if input == "/allfields" {
            let ids: Vec<u32> = api::get_all_field_ids().await?;
            ids.into_iter().map(|id| api::DownloadItem { id, is_field: true }).collect()
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
            if input == "/allcards" {
                run_variants(config);
            }
            continue;
        }

        println!("Downloading {} cards...", to_download.len());
        let result = downloader::download_all(config, &to_download).await?;

        for item in &to_download {
            tracker.mark_downloaded(item);
        }
        tracker.save()?;

        println!("Done: {} succeeded, {} failed.", result.succeeded, result.failed);
        if input == "/allcards" {
            run_variants(config);
        }
    }

    println!("Bye!");
    Ok(())
}

/// Copy official HD art to Anime/VG/Pre-Errata/reprint variants (see variants.rs)
fn run_variants(config: &config::Config) {
    println!("Copying official HD art to Anime/VG/reprint variants...");
    match variants::apply_variant_art(config) {
        Ok(r) => println!(
            "Variant art: {} images copied ({} by alias, {} by name).",
            r.copied, r.by_alias, r.by_name
        ),
        Err(e) => eprintln!("Variant art failed: {}", e),
    }
}
'@ | Set-Content -Path "src\main.rs" -Encoding UTF8

# --- src/api.rs ---
@'
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

/// Fetch a card list from the API and return every image ID in it
async fn fetch_image_ids(url: &str, what: &str) -> Result<Vec<u32>> {
    let resp = reqwest::get(url)
        .await
        .with_context(|| format!("Failed to fetch {}", what))?;
    let body: ApiResponse = resp
        .json()
        .await
        .with_context(|| format!("Failed to read {}", what))?;
    let mut ids = Vec::new();
    for card in &body.data {
        for img in &card.card_images {
            if img.id != 0 {
                ids.push(img.id);
            }
        }
    }
    Ok(ids)
}

/// Get ALL image IDs from the full card list (no filter).
/// Note: this list never includes Rush Duel cards; see `variants::local_rush_ids`.
pub async fn get_all_card_ids() -> Result<Vec<u32>> {
    let mut ids = fetch_image_ids(API_BASE, "card list").await?;
    ids.sort();
    ids.dedup();
    Ok(ids)
}

/// Get field spell image IDs
pub async fn get_all_field_ids() -> Result<Vec<u32>> {
    let url = format!("{}?type=spell%20card&race=field", API_BASE);
    let mut ids = fetch_image_ids(&url, "field list").await?;
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
'@ | Set-Content -Path "src\api.rs" -Encoding UTF8

# --- src/config.rs ---
@'
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
'@ | Set-Content -Path "src\config.rs" -Encoding UTF8

# --- src/downloader.rs ---
@'
use crate::api::DownloadItem;
use crate::config::Config;
use anyhow::Result;
use futures::stream::{self, StreamExt};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

pub struct DownloadResult {
    pub succeeded: usize,
    pub failed: usize,
}

/// ID conversion table (mirrors Go's idConversionMap)
fn convert_id(card_id: u32) -> u32 {
    match card_id {
        904186 => 31533705,
        _ => card_id,
    }
}

pub async fn download_all(config: &Config, items: &[DownloadItem]) -> Result<DownloadResult> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .user_agent("edopro-hd-rust/1.0")
        .build()?;

    // Never download over protected custom card images
    let items: Vec<&DownloadItem> = items.iter().filter(|item| !config.is_protected(item.id)).collect();

    let succeeded = AtomicUsize::new(0);
    let failed = AtomicUsize::new(0);
    let total = items.len();
    let done = AtomicUsize::new(0);
    let semaphore = Arc::new(tokio::sync::Semaphore::new(config.concurrency));

    let _ = stream::iter(items.into_iter())
        .map(|item| {
            let client = &client;
            let config = &config;
            let semaphore = Arc::clone(&semaphore);
            let succeeded = &succeeded;
            let failed = &failed;
            let done = &done;
            let total = total;

            async move {
                let _permit = semaphore.acquire_owned().await.unwrap();

                let converted_id = convert_id(item.id);

                let url = if item.is_field {
                    format!("https://images.ygoprodeck.com/images/cards_cropped/{}.jpg", converted_id)
                } else {
                    format!("https://images.ygoprodeck.com/images/cards/{}.jpg", converted_id)
                };

                // Filename uses the ORIGINAL id (what EDOPro expects), not the converted one
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

# --- src/variants.rs ---
@'
//! Give Anime / VG / Pre-Errata / reprint cards the HD artwork of the official card they are based on.
//!
//! YGOPRODeck has no images for EDOPro's unofficial cards, but most of them are versions of an
//! official card. Matching is done with EDOPro's own card databases (`.cdb` files), in this order:
//!   1. the card's `alias` points to an official card that has an HD image,
//!   2. its name is identical to an official card's name,
//!   3. its name without a trailing "(Anime)", "(VG)", "(Manga)", "(Skill)"... matches one.
//!
//! Rush Duel cards only take art from Rush Duel cards (Rush reprints, once the Rush art is
//! downloaded), never from OCG/TCG cards. Tokens are skipped. Only missing or low-resolution images
//! are replaced, so HD art and custom card art are never overwritten. Every copy is logged in
//! `variant_art_log.csv`.

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

/// Rush Duel card IDs from EDOPro's own databases (main prints only; reprints get their art from
/// `apply_variant_art`). YGOPRODeck's API lists no Rush cards, but its image server has art for
/// many of them, so these IDs are downloaded directly; the ones it doesn't have just fail.
pub fn local_rush_ids(config: &Config) -> Result<Vec<u32>> {
    let cards = load_cards(config)?;
    let mut ids: Vec<u32> = cards
        .iter()
        .filter(|(id, c)| {
            c.ot & SCOPE_RUSH != 0 && c.alias == 0 && c.kind & TYPE_TOKEN == 0 && !config.is_protected(**id)
        })
        .map(|(id, _)| *id)
        .collect();
    ids.sort_unstable();
    Ok(ids)
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

    // Card with HD art per (name, is Rush), preferring the main artwork (alias 0)
    let is_rush = |card: &CardRow| card.ot & SCOPE_RUSH != 0;
    let mut ids: Vec<u32> = hd.keys().copied().collect();
    ids.sort_unstable();
    let mut by_name: HashMap<(String, bool), u32> = HashMap::new();
    for id in ids {
        let card = &cards[&id];
        let key = (card.name.to_lowercase(), is_rush(card));
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
        if hd.contains_key(&id) || card.kind & TYPE_TOKEN != 0 || config.is_protected(id) {
            continue;
        }

        // Rush cards only take Rush art; everything else only takes OCG/TCG art
        let rush = is_rush(card);
        let same_kind = |src: &u32| cards.get(src).map_or(false, |s| is_rush(s) == rush);
        let name = card.name.to_lowercase();
        let (source, by_alias) = if card.alias != 0 && hd.contains_key(&card.alias) && same_kind(&card.alias) {
            (card.alias, true)
        } else if let Some(&src) = by_name.get(&(name.clone(), rush)) {
            (src, false)
        } else if let Some(&src) =
            strip_suffix(&name).and_then(|base| by_name.get(&(base.to_string(), rush)))
        {
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
'@ | Set-Content -Path "src\variants.rs" -Encoding UTF8

# --- Cargo.toml ---
@'
[package]
name = "edoprorusthddownloader"
version = "0.2.0"
edition = "2021"

[dependencies]
tokio = { version = "1", features = ["full"] }
# rustls instead of the system TLS library: no OpenSSL needed, so the binaries are portable
reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls", "http2"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
clap = { version = "4", features = ["derive"] }
anyhow = "1"
futures = "0.3"
urlencoding = "2"
rusqlite = { version = "0.31", features = ["bundled"] }

[profile.release]
# Smaller portable binaries
strip = true
lto = true
codegen-units = 1
'@ | Set-Content -Path "Cargo.toml" -Encoding UTF8

Write-Host "All files written. Now run: cargo build --release" -ForegroundColor Green
