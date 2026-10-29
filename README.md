# MacMP4

**Fast, lossless, batch video → MP4 converter for macOS.**

Drop in `.ts` files (or `mkv` / `m2ts` / `flv` / `avi` / `mov` / …) and get `.mp4` back — no re-encoding, no quality loss, usually hundreds of times faster than realtime. Includes automatic repair for damaged recordings.

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](#requirements)
[![License](https://img.shields.io/badge/license-Noncommercial-blue)](LICENSE)
[![Powered by](https://img.shields.io/badge/powered%20by-ffmpeg-orange)](https://ffmpeg.org)

[繁體中文說明 →](README.zh-TW.md)

---

## Why MacMP4?

`.ts` (MPEG-TS) files — TV recordings, stream captures, downloads — often refuse to open, play badly, or seek incorrectly in QuickTime and other players. The right fix is a **remux** (rewrap into an MP4 container without touching the video/audio bits), but doing it from the command line is inconvenient, and *a single corrupt packet can abort a whole conversion*.

MacMP4 wraps a fast remux engine with a forgiving, auto-fallback pipeline into a tiny native Mac app.

## Features

- 🚀 **Lossless & fast** — video and audio are stream-copied, never re-encoded. A 1.2 GB / 1 h 46 min file converts in ~60 s; the CPU stays idle (it's disk-bound).
- 🗂 **Batch queue** — drag in files or whole folders; per-file progress, speed, and a Finder reveal button.
- 🩹 **Automatic repair** — every file walks a fallback chain until one step succeeds:
  1. **Lossless remux** — `-c copy`
  2. **Audio repair** — video copied, audio re-encoded (fixes the common "corrupt AAC frame" failure that kills plain remuxes)
  3. **Full re-encode** — GPU first, CPU fallback (see below)
- 🧯 **Damage-tolerant** — corrupt packets are skipped (`-err_detect ignore_err -fflags +discardcorrupt`) instead of aborting the conversion.
- 🎛 **GPU acceleration** — the re-encode fallback uses Apple's **VideoToolbox** hardware encoder (`h264_videotoolbox`) by default, with automatic fallback to CPU x264 (CRF 18).
- 📁 **Output next to the source** by default, or choose any folder.
- 🌐 **Bilingual UI** — English / Traditional Chinese, follows the system language (in-app override available).
- ⌨️ **CLI included** for scripting.

## Supported input formats

`ts · m2ts · mts · tp · trp · mkv · flv · f4v · avi · mov · wmv · webm · mpg · mpeg · vob · rm · rmvb · ogv · 3gp · asf · mxf · dv …`

MP4-friendly codecs (H.264/H.265/AV1 video; AAC/MP3/AC3/E-AC3/ALAC audio) are remuxed losslessly. Anything else is routed through the re-encode fallback.

## Requirements

- macOS 13 (Ventura) or newer
- [ffmpeg](https://ffmpeg.org) — install with `brew install ffmpeg`

## Build & run

```bash
git clone https://github.com/jimmyLC/MacMP4.git
cd MacMP4
./build.sh
open build/MacMP4.app
```

Install to /Applications:

```bash
cp -R build/MacMP4.app /Applications/
```

The build produces:

- `build/MacMP4.app` — the drag & drop GUI
- `build/macmp4-cli` — the command-line version

## Usage — GUI

1. Launch `MacMP4.app`
2. Drag in video files or folders (or use the *Add files* / *Add folder* buttons)
3. Review the queue and output location, then click **Start conversion**. Immediate conversion is optional. Per-file progress and speed are shown live
4. Click the folder icon on a finished row to reveal the MP4 in Finder

Options: output location, overwrite existing MP4s, automatic re-encode fallback, GPU acceleration.

> Pro tip: right-click a `.ts` file in Finder → **Open With → MacMP4**.

## Report a problem (GUI)

A file that fails again after one retry shows a **Report a Problem** button next to Retry; a one-off failure is usually fixed by trying again. The same command is always available under **Help → Report a Problem…**. It opens https://support.jimmy-tools.com/add in your browser with the app version, macOS version, ffmpeg version and the tail of ffmpeg's error output already filled in. File names, folder names, volume names and email addresses are removed from that log before the link is built.

The diagnostics travel in the URL fragment (`#d=…`), which a browser never sends to a server. Nothing leaves your Mac until you read the form and press Send, and you can switch the diagnostics off there. Video files are never uploaded.

## Basic trimming (GUI, advanced option)

Open **Advanced options → Trim start / end**, then enter seconds to remove from the start and/or end (decimals supported). The option is off by default and applies to every waiting file in the current batch. Set one side to 0 to keep that edge. The retained video is re-encoded as H.264/AAC MP4 using hardware acceleration with CPU fallback, even when ordinary re-encode fallback is off.

Trimming also accepts MP4/M4V inputs. Outputs use `<basename>_trimmed.mp4` in the selected output location; source files stay intact. Existing trimmed outputs obey the overwrite option. Invalid numbers, unknown duration or cuts that remove the entire video are rejected. Progress uses the retained duration. Turn trimming off to return to the original fast remux flow and MP4/M4V skip behavior. This option is available in Free and Pro; the CLI remains unchanged.

## Usage — CLI

```bash
macmp4-cli video.ts                       # → video.mp4 next to it
macmp4-cli --out ~/Movies folder/*.ts     # choose output folder
macmp4-cli --no-overwrite a.ts b.mkv      # skip existing outputs
macmp4-cli --no-gpu --no-reencode x.ts    # strict: copy-only strategies
```

| Option | Meaning |
|---|---|
| `--out <dir>` | Output folder (default: same folder as source) |
| `--no-overwrite` | Skip files whose MP4 already exists |
| `--no-reencode` | Disable the full re-encode last resort |
| `--no-gpu` | Use CPU x264 instead of the VideoToolbox encoder |
| `--force-h264` | Always output H.264 video + AAC audio (cannot combine with `--no-reencode`) |

Same-named outputs in one run are never overwritten: `a.ts` and `a.mkv` produce `a.mp4` and `a 2.mp4`. All audio tracks are kept. `--out` creates the folder if needed.

## GPU acceleration, explained

Remuxing does not decode or encode anything — it is pure I/O. It already runs at disk speed, so a GPU has nothing to accelerate there. GPU only matters for the **re-encode fallback**, which rescues files that cannot be remuxed (e.g. MPEG-2 TV recordings):

| Path | Work done | Acceleration |
|---|---|---|
| Lossless remux | none (stream copy) | I/O bound — already at max speed |
| Audio repair | AAC encode only | multithreaded (negligible cost) |
| Full re-encode | decode + encode video | **VideoToolbox GPU / media engine** first, CPU x264 fallback |

## Under the hood

1. `ffprobe` inspects codecs and duration.
2. A strategy list is chosen based on MP4 compatibility.
3. Each strategy runs with `-err_detect ignore_err -fflags +discardcorrupt -movflags +faststart`.
4. The output file is re-probed for validity before success is declared.

## Project layout

```
Sources/Engine.swift    ffprobe/ffmpeg core (no UI dependencies)
Sources/Model.swift     batch queue & conversion logic
Sources/App.swift       SwiftUI interface
CLI/main.swift          command-line front-end
assets/makeicon.swift   generates the app icon
build.sh                build script
```

## License

[MacMP4 Noncommercial License 1.0](LICENSE)

Copyright © 2026 **JimmyLC** · [Developer website](https://jimmy-tools.com/)

Source code is available. You may use, study, modify and redistribute MacMP4 for noncommercial purposes free of charge, retaining the copyright notice, developer attribution, website and license. **Commercial use is prohibited**, including business operations, professional/client work, paid services and commercial bundling, unless JimmyLC grants a separate written license.

This is source-available software with a noncommercial restriction, rather than OSI-approved open-source software. Earlier MIT releases and rights already granted under MIT remain unaffected. Third-party tools retain their own licenses. The English LICENSE file contains the full terms.

## Output safety and regression checks

Conversions are staged beside the destination and validated before the final MP4 is atomically replaced. Failed or cancelled attempts preserve existing output files. Directory and symbolic-link destinations are rejected. Valid sub-second clips are supported.

Run `python3 Tests/regressions.py` on macOS with Swift, Python 3, ffmpeg and ffprobe installed. The suite uses disposable synthetic media and covers CLI conversion, GUI queue-model cancellation, output preservation and noisy probing.

## Interface and languages

The queue sits beside a persistent output inspector, with Start/Stop in the bottom action shelf. Advanced options are collapsed initially. Clearing completed retains failed items for retry. The interface supports system default, Traditional Chinese and English through the inspector's Language menu. Some existing job messages may require reopening the app to fully adopt a language change.

On macOS 26+, the import control and action shelf use native Liquid Glass. Earlier systems use standard system material. File rows stay readable, and system Reduce Transparency / Reduce Motion preferences are respected. The app icon uses a simple pair of opposing blue arrows.

## Download and build a DMG

Download the Apple Silicon build from [GitHub Release v1](https://github.com/jimmyLC/MacMP4/releases/tag/v1). It requires macOS 13+ and separately installed ffmpeg/ffprobe. This release is ad-hoc signed, without Developer ID signing or Apple notarization.

To build from source, use Xcode with the macOS 26 SDK or later, then run `./build-dmg.sh`. The package contains MacMP4.app, an Applications shortcut, LICENSE and bilingual installation instructions. The script verifies the disk image and writes build/SHA256SUMS.txt. The app's display version comes from VERSION.

On launch, MacMP4 checks for both FFmpeg and ffprobe. If either is missing, setup offers **Install FFmpeg** through an existing Homebrew installation, with live output and retry on failure. Without Homebrew, setup links to its official instructions. Returning to the app rechecks the tools without restarting. Homebrew currently supports macOS 15+; on older macOS versions, install compatible tools separately.

Free displays a Free badge and always uses Light appearance. Pro displays a Pro badge and supports Light, Dark and Follow System, with the appearance preference saved between launches. All conversion features remain available in Free. Pro is a one-time NT$90 lifetime purchase with in-app checkout and email/serial activation. Developer previews can compile with `-D MACMP4_PREVIEW_PRO`; build.sh never sets that flag.

The Advanced options include **Force H.264**, off by default and available in both Free and Pro. When enabled, conversion skips stream-copy strategies and uses H.264 video plus AAC audio (if the source has audio), with VideoToolbox and CPU fallback. This takes precedence over the normal re-encode fallback setting. The CLI equivalent is `--force-h264`; it cannot be combined with `--no-reencode`. Existing MP4/M4V and no-overwrite skip rules are unchanged.

The support entry is **Super Thanks**, with a heart-and-dollar icon. The panel describes the NT$90 lifetime Pro edition and its checkout.

## Pro payment integration

A SHOPLINE Payments checkout and signed lifetime license flow is built in, with a separate Cloudflare Worker/D1 backend. Pro costs NT$90 once; conversion remains free. This store currently accepts Taiwan-issued credit cards only. See [integration and release gates](docs/SHOPLINE_INTEGRATION.md).

After the first verified purchase, the app shows a brief fireworks celebration and a Pro welcome. License restoration does not replay it; Reduce Motion skips the animation.
