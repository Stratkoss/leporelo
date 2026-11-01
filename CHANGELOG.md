# Changelog

## 0.1.0-beta (2026-11-01)

First public beta.

- Reads the Apple Photos library through PhotoKit (iCloud-only originals included); start window with albums, shared albums and date ranges.
- Local Vision analysis: sharpness, closed eyes, aesthetics, duplicates and bursts; per-day recommendations; grouping by day and place.
- Automatic draft of a "diary + gallery" book.
- Spread editor: free-form frames and text, tiered snapping, book margin, per-text fonts, crop mode, copy/cut/paste, undo, autosave and Versions.
- Preflight and PDF export for the Canva Print profile (unverified dimensions).
- Command line tool `leporelo-cli` for the whole flow on a folder of photos.
- Fix: the Debug build compiled with Xcode 27.2 failed on a Swift 6 region-isolation error in `SpreadCanvasView`.

Known limits are listed in the README.
