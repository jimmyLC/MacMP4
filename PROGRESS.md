# Progress

Last updated: 2026-10-27

## Current state

- **Version 1.0.0** (see `VERSION`). Apple Silicon DMG published as [GitHub Release v1](https://github.com/jimmyLC/MacMP4/releases/tag/v1); ad-hoc signed, **not** Developer ID signed or notarized.
- Product page and download: https://jimmy-tools.com/MacMP4/ (maintained in the `jimmy-tools-site` repo).
- Features shipped:
  - Lossless remux with the automatic repair chain (lossless copy, audio repair, GPU re-encode, CPU re-encode)
  - Batch queue GUI, bilingual (system default / Traditional Chinese / English), CLI (`macmp4-cli`)
  - Safe output: staged conversion, ffprobe validation, atomic replace
  - Optional trimming (start / end seconds), Force H.264 option
  - First-launch check for ffmpeg and ffprobe, with an install helper through Homebrew
  - Free / Pro badge and appearance modes (Light only in Free; Light / Dark / System in Pro)
- Regression suite: `python3 Tests/regressions.py`.
- License: MacMP4 Noncommercial License 1.0 (source-available, commercial use prohibited; not OSI open source).

## Not done

- [ ] Pro purchase: planned as a one-time NT$90 lifetime license, but checkout and email / serial activation are not connected. Production builds start in Free.
- [ ] "Super Thanks" support panel describes the NT$90 edition, but checkout is not available.
- [ ] Developer ID signing and Apple notarization (the release is ad-hoc signed)
- [ ] Homebrew supports macOS 15+ only; on macOS 13 / 14 users must install compatible ffmpeg tools themselves

## Decisions

- Remux first, re-encode only as a fallback; damage tolerance (`-err_detect ignore_err -fflags +discardcorrupt`) is the core value.
- All conversion features stay available in Free; Pro only adds appearance options (so far).
- Default import flow is add, review, then start; immediate conversion is opt-in.
- Developer previews of Pro compile with `-D MACMP4_PREVIEW_PRO`; `build.sh` never sets it.
- License changed from MIT to Noncommercial; rights already granted under earlier MIT releases are unaffected.
