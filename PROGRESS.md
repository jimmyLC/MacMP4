# Progress

Last updated: 2026-10-28

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

## ECPay integration work — 2026-10-28

On `codex/ecpay-pro`: implemented a separate Worker/D1 payment service, NT$90 fixed-price Apple Pay/card orders, verified/idempotent callbacks, encrypted license storage, P-256 signed lifetime receipts, native checkout/polling, Keychain recovery and email+serial restoration. Taiwan-issued-card limitation is displayed on both payment surfaces. Local Worker/D1 smoke, backend tests, native client security tests and existing regressions pass. Credentials are privately configured; cloud deployment, actual ECPay callbacks, production payment acceptance and public app release remain pending. Checkout is disabled by default. See `docs/ECPAY_INTEGRATION.md` and `docs/ECPAY_PRIVACY_CHECK.md` for evidence and release gates.

## Report a problem — 2026-10-28

On `feat/report-problem`: a job that has failed twice (first attempt plus one retry; `ReportProblem.failuresBeforeOffering`) gets a **Report a Problem** button, and Help → Report a Problem… is always available that opens https://support.jimmy-tools.com with diagnostics in the URL fragment: app / macOS / ffmpeg versions plus the redacted tail of ffmpeg's stderr per attempt. `FF.run` now keeps the last 16 KB of stderr and hands it to an optional `errorOutput` callback; `Job.failureLog` stores the redacted result. Redaction (`ReportProblem.redact`) removes the input path, every other absolute path (extension kept, folder names with spaces covered) and emails. The server (`support-inbox` repo) redacts again as a second layer. Regression suite covers the link format, redaction, bounded log and language choice; the full suite passes. Not done: release build with this change, and a version bump.
