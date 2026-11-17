**This is a Rust based version of the EDOPro HD Downloader tools that have been around for a while, but they are outdated!**

**Feel free to download, modify, redistribute and fork this repo! All I ask that you give a little credit "based on argyris mpalampanis's repo" or something!🙂**

**The repo contains all needed files, just clone the repository and run "Cargo build --release". Alternativly, download the pre-made .exe from the releases page!**

**In case the files return errors, populate them by running "fix.ps1"**

**Just place the downloaded/compiled .exe file to your EDO Pro root folder and run it! Pics will be downloaded to /expansions/pics. Cut and paste the Pics folder to the root folder, once download is finished!**

## Features

- **HD art for every official OCG/TCG card**, plus Field Spell artwork.
- **Rush Duel art.** YGOPRODeck's API doesn't list Rush Duel cards, but its image server has art for many of them (421×614, more than twice the size of EDOPro's own images). The Rush card IDs are read from EDOPro's own card databases and downloaded along with everything else (`/allcards`, `--clean`). Cards YGOPRODeck has no image for show up as failed (HTTP 404) and are skipped on later runs. Rush reprints then get their art from the variant step.
- **HD art for Anime, VG, Manga, Pre-Errata and reprint cards.** YGOPRODeck has no images for EDOPro's unofficial cards, but most of them are versions of an official card. The downloader reads EDOPro's own card databases (`expansions/*.cdb` and `repositories/*/*.cdb`) and copies the official HD artwork to those variants. No extra downloads needed!
  - A variant is matched by its database alias first, then by an identical name, then by its name without a tag like "(Anime)" or "(VG)".
  - Only missing or low-resolution images are replaced, so existing HD art and custom art are never overwritten.
  - Rush Duel cards only take art from Rush Duel cards (e.g. Rush reprints), never from OCG/TCG cards.
  - Anime-only cards (no official version) are skipped.
  - Every copy is listed in `variant_art_log.csv`, next to the copied images. Delete those files to undo.
- **Custom cards are protected.** Card IDs `77711000-77711999` are never deleted by `--clean` and never overwritten by a download. Add your own ranges with `--protect`.

## Usage

Run the .exe with no arguments for interactive mode:

| Command | What it does |
|---|---|
| `/allcards` | Download all new card images (OCG/TCG and Rush Duel), then apply variant art |
| `/allfields` | Download all new Field Spell artwork |
| `/deck <name>` | Download the images of one deck |
| `/ids <123,456>` | Download specific card IDs |
| `/variants` | Only copy HD art to Anime/VG/reprint variants |
| `/clean` | Wipe `expansions/pics` (custom cards are kept) and re-download everything |
| `/quit` | Exit |

Or use the command-line options:

```
edoprorusthddownloader --all-cards                 # download all new images + variant art
edoprorusthddownloader --variants                  # only apply variant art
edoprorusthddownloader --clean                     # re-download everything (custom cards kept)
edoprorusthddownloader --protect 88800000-88800999 # protect more custom card IDs
edoprorusthddownloader --help                      # all options
```

Variant art is copied next to the official image it comes from: into `expansions/pics` for fresh downloads, or into the root `pics` folder for images you already moved there.
