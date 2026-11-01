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

    let succeeded = AtomicUsize::new(0);
    let failed = AtomicUsize::new(0);
    let total = items.len();
    let done = AtomicUsize::new(0);
    let semaphore = Arc::new(tokio::sync::Semaphore::new(config.concurrency));

    let _ = stream::iter(items.iter())
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