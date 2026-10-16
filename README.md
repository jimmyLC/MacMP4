# MacMP4

**Fast, lossless, batch video → MP4 converter for macOS.**

Drop in `.ts` files (or `mkv` / `m2ts` / `flv` / `avi` / `mov` / …) and get `.mp4` back — no re-encoding, no quality loss, usually hundreds of times faster than realtime. Includes automatic repair for damaged recordings.

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
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
3. Conversion starts automatically (toggleable). Per-file progress and speed are shown live
4. Click the folder icon on a finished row to reveal the MP4 in Finder

Options: output location, overwrite existing MP4s, automatic re-encode fallback, GPU acceleration.

> Pro tip: right-click a `.ts` file in Finder → **Open With → MacMP4**.

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

[MIT](LICENSE)
