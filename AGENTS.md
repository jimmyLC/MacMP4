# AGENTS.md — MacMP4

MacMP4 converts video (mainly `.ts`) to MP4 on macOS by **stream-copy remuxing** — no re-encoding — with an automatic repair chain for damaged files. Native SwiftUI + ffmpeg. `README.md` is the user-facing source of truth; this file covers what agents need to change the code safely.

## Architecture

Two targets, one shared core:

| File | Role |
|---|---|
| `Sources/Engine.swift` | ffmpeg/ffprobe core. Foundation/Darwin only, with no UI dependencies; it compiles into both the GUI and the CLI. |
| `Sources/Model.swift` | `JobStore` batch queue; runs the strategy chain per file. |
| `Sources/App.swift` | SwiftUI GUI (`@main`). |
| `CLI/main.swift` | CLI entry; top-level code, so this filename is load-bearing for swiftc. |

### The strategy chain (core design)

`FF.strategies(...)` returns an ordered list, fastest → slowest; `JobStore.process` tries each until one yields a valid output:

1. **無損轉換** — `-c copy` lossless remux
2. **修復音訊** — video copy + AAC re-encode (repairs corrupt AAC frames, the classic remux killer)
3. **GPU 硬體編碼** — `h264_videotoolbox` (Apple VideoToolbox)
4. **重新編碼** — CPU `libx264 -crf 18` last resort

When changing conversion behavior:

- Keep the chain ordered fastest → slowest; insert new strategies at their speed position.
- Every attempt writes inside its own `OutputTransaction` staging directory and is re-validated by ffprobe (a media stream and finite positive duration). Valid sub-second clips are supported. Only staged output is deleted on failure; the final path is replaced atomically after validation. Preserve directory and symlink destinations.
- Every ffmpeg invocation keeps `-err_detect ignore_err -fflags +discardcorrupt` and `-movflags +faststart` — damage tolerance is the app's core value.

### Threading

- One serial worker queue (`macmp4.worker`). Status updates go through `setStatus`, which hops to main; the worker never touches view state directly.
- Stop = `stopRequested` + terminate the live process; the in-flight job returns to `.waiting` so "start" resumes it.

### Skip rules

`.mp4`/`.m4v` inputs and existing outputs (with overwrite off) are skipped. Output is `<basename>.mp4` next to the source, or in the chosen folder.

## Build

```bash
./build.sh    # → build/MacMP4.app + build/macmp4-cli
```

- `build/` is gitignored and wiped on every build.
- The icon is generated: edit `assets/makeicon.swift`; build.sh renders PNG → iconset → icns.
- Install: `ditto build/MacMP4.app /Applications/MacMP4.app`, then `killall Dock` to refresh the icon cache.

## Verify a change

Run `python3 Tests/regressions.py` for output preservation, short clips, noisy probing, GUI model cancellation/state updates, and localization. Also verify the two actual codec paths with the CLI:

```bash
# lossless path: h264 + aac
ffmpeg -y -f lavfi -i "testsrc2=duration=3:size=320x240:rate=30" -f lavfi -i "sine=frequency=440:duration=3" -c:v libx264 -preset ultrafast -c:a aac -f mpegts /tmp/fix-good.ts

# re-encode path: mpeg2video + mp2 (not MP4-compatible)
ffmpeg -y -f lavfi -i "testsrc2=duration=3:size=320x240:rate=30" -f lavfi -i "sine=frequency=440:duration=3" -c:v mpeg2video -c:a mp2 -f mpegts /tmp/fix-mpeg2.ts

build/macmp4-cli --out /tmp /tmp/fix-good.ts /tmp/fix-mpeg2.ts
```

Done when: the build succeeds; the CLI exits 0; both outputs probe as h264 with duration > 0; the log shows 無損轉換 for the first file and a re-encode strategy for the second.

## Conventions

- User-visible strings are written in Traditional Chinese in code and wrapped with `L()`; English translations live in `Resources/en.lproj/Localizable.strings`, keyed by the exact Chinese text. A new string needs both an `L()` wrap and an en entry.
- `README.md` (English) and `README.zh-TW.md` (Chinese) mirror each other; update both when behavior changes.
- Locate ffmpeg with `FF.findTool`, which searches Homebrew paths because GUI apps don't inherit the shell `PATH`.

## UI and localization changes

- The default import flow is add → review queue/output location → start. Immediate conversion is opt-in.
- The queue observes each job so summary counts and progress update live. Clearing completed preserves failures for retry; probing/converting entries remain in the queue.
- Use native glassEffect only behind macOS 26 availability checks; older systems use system material, and Reduce Transparency uses a solid surface. Keep file content readable and respect Reduce Motion.
- Language choices remain system default, Traditional Chinese and English. New interface strings, panel prompts, tooltips and accessibility labels use L() with complete English resources. Run the localization regression after adding or changing format placeholders.
- For the design rationale and layout decisions, read docs/UI_DESIGN.md when changing the workspace. For icon geometry, edit assets/makeicon.swift; the reference is a pair of thin, straight, opposing blue arrows.
