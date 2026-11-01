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
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let config = config::Config::new(cli.edopro_path.clone(), cli.concurrency);

    if cli.clean {
        println!("Wiping {} ...", config.pics_path.display());
        config.wipe_pics()?;
        println!("Done. Starting fresh download.\n");

        let mut tracker = tracker::Tracker::new(&config)?;
        let items = collect_all().await?;
        println!("Found {} images to download.", items.len());

        let result = downloader::download_all(&config, &items).await?;

        for item in &items {
            tracker.mark_downloaded(item);
        }
        tracker.save()?;

        println!("\nDone: {} succeeded, {} failed.", result.succeeded, result.failed);
        return Ok(());
    }

    config.setup_dirs()?;
    let mut tracker = tracker::Tracker::new(&config)?;

    if cli.all_cards || cli.all_fields || cli.deck.is_some() || cli.ids.is_some() {
        let items: Vec<api::DownloadItem> = if cli.all_cards || cli.all_fields {
            collect_all().await?
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

/// Collect all card images + field images (mirrors the Go version exactly)
async fn collect_all() -> Result<Vec<api::DownloadItem>> {
    let mut items = Vec::new();

    let card_ids: Vec<u32> = api::get_all_card_ids().await?;
    for id in card_ids {
        items.push(api::DownloadItem { id, is_field: false });
    }

    let field_ids: Vec<u32> = api::get_all_field_ids().await?;
    for id in field_ids {
        items.push(api::DownloadItem { id, is_field: true });
    }

    Ok(items)
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
    println!("Commands: /allcards, /allfields, /deck <name>, /ids <123,456>, /clean, /quit");

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
            config.wipe_pics()?;
            println!("Done. Starting fresh download.\n");

            let items = collect_all().await?;
            println!("Found {} images to download.", items.len());
            let result = downloader::download_all(config, &items).await?;

            for item in &items {
                tracker.mark_downloaded(item);
            }
            tracker.save()?;

            println!("Done: {} succeeded, {} failed.", result.succeeded, result.failed);
            continue;
        }

        let items: Vec<api::DownloadItem> = if input == "/allcards" {
            let ids: Vec<u32> = api::get_all_card_ids().await?;
            ids.into_iter().map(|id| api::DownloadItem { id, is_field: false }).collect()
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