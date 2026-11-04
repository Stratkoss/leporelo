English · [Česky](README.cs.md)

# Leporelo

**Turn a vacation's worth of Apple Photos into a print-ready photo book, without giving up halfway.**

> **Status: beta (v0.1.0-beta).** A working native macOS app and a tested core library. It has been built for, and used by, a very small group of people. It is not signed or notarized, and several things could not be verified without a real Photos library and a real print order (see [Status and honesty](#status-and-honesty)).

## The problem

After a week-long trip a phone holds around 3,000 photos, mostly in iCloud with "Optimize Storage" switched on. Making a photo book out of that is where people quit: existing editors cannot reach the Apple Photos library on a Mac, they are slow, and their "AI" features do little. The book never gets made.

## What Leporelo does

1. **Reads your Apple Photos library directly** (PhotoKit), including photos whose originals only live in iCloud. It works on thumbnails first and downloads originals only for the photos that end up in the book, in the background.
2. **Sorts and scores locally.** Photos are grouped by day and place. On-device Vision analysis scores sharpness, closed eyes, aesthetics, near-duplicates and burst series, then recommends a pick for each day. No cloud, no API keys, no photo leaves the Mac. A human makes the final selection.
3. **Drafts a whole book** in a "diary + gallery" style: a diary spread opens each day or place, gallery spreads follow. You start from a draft, not a blank page.
4. **Edits spreads freely.** Free-form frames and text with tiered snapping, a configurable book margin, per-text fonts, crop mode, copy/paste across albums, full undo, autosave and macOS Versions.
5. **Checks before print.** Preflight verifies resolution, safe zone, page count, missing originals and text overflow, and blocks the export until the book is printable.
6. **Exports print PDF** to a supplier profile (first target: Canva Print), with the fonts embedded and a `co-nahrat-kam.txt` upload walkthrough (Czech).

### Design principles

- **Never lose work.** Standard macOS document model, every change is saved within seconds.
- **No bad prints.** Everything that can be checked before export is checked.
- **No waiting.** Heavy work runs in the background; the app is usable in seconds on a 3,000-photo library.
- **Self-contained projects.** A book is a `.leporelo` package holding the album JSON, thumbnails and copies of the originals, so export does not depend on iCloud being reachable or on the photo still being in Photos.

## Try the beta

Requirements: macOS 15 or newer. Developed and tested on Apple Silicon with macOS 26.

1. Download `Leporelo-0.1.0-beta-macOS.zip` from the [Releases](../../releases) page and unzip it.
2. The app is **ad-hoc signed, not notarized**. On first launch, right-click `Leporelo.app` > Open, or run `xattr -dr com.apple.quarantine Leporelo.app`.
3. In the start window click "Povolit přístup k Fotkám" (Allow access to Photos) and grant **full** access.
4. Pick an album or a date range, click "Udělat z toho knihu", and follow the diary-and-gallery flow.

The user interface is currently **Czech only**.

No Photos library at hand? The command line runs the whole pipeline on a folder of JPEGs:

```
make cli
.build/debug/leporelo-cli draft --folder ~/Pictures/trip --title "Greece 2026" --out ~/Desktop/leporelo-out
```

## Build from source

Needs Xcode (the Command Line Tools alone lack the Testing module) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
make test        # core library tests (449)
make test-app    # app tests (330)
make build-app   # generate the Xcode project and build the app (Debug)
make run-app     # launch it
make all         # all of the above
```

`make help` lists every target. The Makefile pins `DEVELOPER_DIR` to `/Applications/Xcode.app`, so system settings stay untouched. The Xcode project is generated from `App/project.yml` and is not checked in.

## Architecture

| Path | Role |
| --- | --- |
| `Sources/LeporeloCore/` | UI-free core in Swift 6: model, day/place grouping, analysis and scoring, album drafting and page planning, snapping, rendering, preflight, PDF export, project package, supplier profiles, photo sources |
| `Sources/leporelo-cli/` | thin command line over the same `Workflow` |
| `App/` | the Mac app (SwiftUI, AppKit for the photo grid and spread canvas, PhotoKit) |
| `Tests/`, `App/LeporeloTests/` | 449 core tests and 330 app tests (Swift Testing) |
| `docs/` | design specs, implementation plans, manual verification checklist |

Pipeline: `PhotoSource` > analysis (Vision, local) > grouping by day and place > recommendation > `AlbumDrafter` / `PagePlanner` > editor > preflight > `PDFExporter`.

Supplier profiles are data, not code: add a JSON file to `Sources/LeporeloCore/Resources/Profiles` and it shows up in the app and the CLI. The format is documented in the [Czech README](README.cs.md#jak-přidat-profil-dodavatele).

Further reading: [design document](docs/superpowers/specs/2026-10-26-album-app-design.md) (Czech), [manual verification checklist](docs/manual-verification.md) (Czech).

## Status and honesty

What is solid: the core pipeline and editor logic are covered by 779 automated tests, and the full flow from a folder of photos to a PDF is tested end to end.

What is **not** verified yet:

- The Canva Print profile (page formats, bleed, safe zone, 98-page maximum) is marked `verified: false`. The numbers were not yet checked against a real order, and it is unknown whether Canva recompresses photos when importing the PDF.
- PhotoKit behaviour against a large real library (iCloud-only originals, shared albums, limited access) follows the documented checklist in `docs/manual-verification.md`, which has not been fully walked through.
- No physical book has been printed from this pipeline yet.

## Known limits of the beta

- One supplier profile (Canva Print, unverified). Saal Digital is designed but not implemented: wrap-around cover with spine width is rejected by the exporter.
- One visual world ("diary + gallery"). Scrapbook and mosaic spreads are planned.
- The cover is shown but cannot be edited yet.
- Reads a single Photos library. Photos from a second person must be in the same library, ideally as originals.
- Videos are ignored. Import from a folder is CLI-only.
- AI recommends photos; it does not write the text. Texts are written by a person.
- The interface is Czech, the macOS system menus are English; there is no localization bundle yet.
- Place names use network reverse geocoding, rate limited to one request per second, and arrive after sorting is already usable.

The full list, with workarounds, is in the [Czech README](README.cs.md#známé-limity-verze-1).

## Roadmap

From the design document, not promises: Saal Digital profile with wrap-around cover, scrapbook world and mosaic spreads, cover editing, English localization, signed and notarized distribution.

## License and fonts

The code is released under the [MIT License](LICENSE). The bundled fonts Fraunces and Schibsted Grotesk are under the SIL Open Font License 1.1 (texts in `Sources/LeporeloCore/Resources/Fonts/`) and are embedded in exported PDFs.
