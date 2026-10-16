# MacMP4 review — 2026-10-16

Reviewed upstream initial version `69d6b4d` (all tracked source files), plus the local icon changes on `codex/macos-icon`. No originating issue, dedicated specification, AGENTS.md, coding standards, or issue-tracker configuration exists in this repository. README.md and README.zh-TW.md serve as the behavior specification. The two review axes were inspected independently. Findings below refer to upstream source line numbers, unchanged by the icon work.

## Standards

No documented-standard violations can be asserted without a standards document.

1. **[P1] Existing output is not preserved on failure.** `Sources/Engine.swift:115–120` passes `-y` directly to the final output path. `Sources/Model.swift:289` and `CLI/main.swift:140` delete that path after a failed attempt. With overwrite enabled, failed conversion or cancellation can destroy an existing MP4. Even a launch failure enters cleanup. Write each attempt to a unique sibling temporary file; validate it and replace the destination only after success. Never remove a destination that the current attempt did not create.
2. **[P1] ffprobe stderr can deadlock probing.** `Sources/Engine.swift:43–46` assigns stderr to a pipe without draining it, then synchronously waits for stdout. A filled stderr pipe blocks the child and prevents stdout from closing. Verified using a compiled harness and a mock probe writing 1 MB to stderr before JSON: it failed to complete within three seconds and required termination. Drain stderr concurrently or redirect it to the null device. GUI cancellation currently receives only conversion processes, so it cannot terminate a blocked probe.
3. **Possible Duplicated Code — judgment call.** `Sources/Model.swift:225–293` and `CLI/main.swift:84–145` duplicate output selection, validation, retries, and cleanup. They already differ in empty-stream checks. A shared conversion lifecycle would keep future safety fixes consistent between GUI and CLI.

Standards axis: two correctness findings and one heuristic; highest priority P1.

## Spec

1. **[P1] Cleanup can recursively delete a preexisting directory.** The README permits overwriting existing MP4 files; `CLI/main.swift:140` and `Sources/Model.swift:289` perform unrestricted `removeItem(at:)` on the final destination. Reproduced with a valid `normal.ts` and a preexisting `normal.mp4/` directory containing a sentinel: ffmpeg failed to open the directory, cleanup deleted the directory and sentinel, and a fallback replaced it with a video. CLI overwrite is enabled by default. This is an additional demonstrated consequence of Standards finding 1, not a separate underlying defect. Reject non-file destinations and use temporary output plus safe commit semantics.
2. **[P2] Valid clips of 0.5 seconds or less cannot succeed.** `CLI/main.swift:133` and `Sources/Model.swift:283` require output duration strictly greater than 0.5 seconds. A valid 0.2-second H.264 MPEG-TS fixture exhausted all three CPU strategies, had its output deleted, and was reported as possibly corrupt. README declares no minimum input duration. Validate stream presence and positive duration, accounting for source duration and container rounding rather than a fixed half-second cutoff.

Spec axis: two findings; highest priority P1. There are three unique correctness defects across the two axes.

## Verification and limits

- Compiled the existing CLI in Swift 5 mode and exercised the directory-deletion and short-clip cases with synthetic media and installed ffmpeg. All files used for reproductions were disposable fixtures under `/private/tmp`.
- Compiled and ran a probe harness for the stderr deadlock.
- GUI counterparts were inspected in source; the conversion scenarios were not exercised through the GUI.
- Icon work does not change the conversion engine or resolve these findings. The three correctness defects were subsequently fixed in this worktree; see the resolution below. The broader lifecycle-duplication observation remains a future refactoring opportunity.

## Icon integration verification

- Full arm64 GUI and CLI build succeeded with the macOS 13 deployment target. The SwiftUI macro compiler required execution outside the outer sandbox.
- The packaged AppIcon.icns was extracted successfully; checked the 16 px and 1024 px entries and source PNG alpha channel. Info.plist references AppIcon.
- `codesign --verify --deep --strict` and CLI `--help` succeeded; `git diff --check` passed.
- Visually inspected the generated 1024 px icon. Finder/Dock cache behavior and live GUI conversion remain unverified.

## Resolution — 2026-10-16

All three correctness defects are fixed locally:

- Shared `OutputTransaction` gives GUI and CLI a private sibling staging directory. Failed attempts only delete their own staged output. Existing directories and symbolic links are rejected. After output validation, same-volume atomic rename replaces a regular file; no-overwrite uses an exclusive atomic rename (`RENAME_EXCL`) to avoid clobbering newly arrived files.
- ffprobe sends diagnostics to the null device instead of an undrained pipe. GUI probing also registers its process for Stop; the stop flag is protected by a lock, and launch registration checks for pending cancellation.
- Shared output validation requires a real media stream and finite positive duration, removing the half-second cutoff.

`python3 Tests/regressions.py` first reproduced all three upstream defects (three FAIL results). After the fixes, it checks real CLI conversion of a synthetic 0.2-second H.264 transport stream, directory preservation, a probe producing 1 MB of stderr, transaction behavior (including exclusive creation without hard links), and the actual GUI JobStore model with a pumped main run loop. GUI model cases cover successful short clips, preservation of directories and existing files, stopping conversion and probing, invalid staged output, and temporary-file cleanup. Tool injection is limited to JobStore initializer defaults so production tool discovery is unchanged.

Tests use synthetic disposable files and mock tools, not user media. The native window and Finder/Dock icon cache still require a visual runtime check. Physical exFAT/FAT32 destination volumes were not available for testing; no-overwrite uses macOS exclusive rename instead of hard links. Full arm64 GUI/CLI build and strict code-signature verification passed after the fixes and revised icon integration. A third-party encoder that ignores termination, or an application killed abruptly, may leave its private staging directory; the final output is still kept separate until commit.
