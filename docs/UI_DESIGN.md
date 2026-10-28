# MacMP4 — UI/UX redesign

## Direction

A calm native conversion workspace. The queue is the content, output is the persistent inspector, and the bottom action is always the next step. Avoid media-player imagery, decorative dashboards, and repeated cards.

Palette: workspace #F4F6F9, content #FFFFFF, ink #1D2433, secondary #687385, conversion accent #2670E8, success #23855B. Use semantic system colors for actual surfaces and text so dark mode, contrast and transparency settings remain supported.

Typography: macOS system San Francisco; 24 pt semibold empty-state title, 20 pt workspace heading, 13 pt filenames and controls, 11–12 pt metadata. No third-party font. Left-aligned working content; centered empty-state invitation.

Layout:

```
Native titlebar                  Add files / Add folder
Queue heading + counts           Output inspector
                                 MP4 • keep original video when possible
File rows + individual progress   Save location
or a restrained empty state      Advanced options

Glass action shelf: overall state / clear completed / start or stop
```

Use glass only for the action shelf and the compact import control. Keep file content opaque and readable. On macOS 26+, use SwiftUI glassEffect; on 13–15 use system material; with Reduce Transparency use a solid surface. Respect Reduce Motion. Keep all buttons labeled, provide keyboard shortcuts and VoiceOver labels, and show errors as text with retry actions.

## Flow decisions

- Default to review-before-convert: add files, inspect output destination, then start. Immediate conversion remains opt-in.
- Output destination is always visible, changeable in one action, and fixed while running.
- Advanced conversion choices are collapsed initially; show honest copy: lossless first, re-encoding may be needed. Do not promise every conversion is lossless.
- Large filenames, separate metadata/status, actual per-file progress, Finder reveal on completion, retry on failure.
- Clear completed removes completed/skipped entries only; failures remain for review. Active/probing entries cannot be removed.
- Counts and total progress observe nested job changes. Failed/skipped files count as processed without being labeled successful.

## Review before implementation

A sidebar and dashboard metrics would add navigation to a one-job utility. Use one workspace and one narrow output inspector instead. A full-glass file list would reduce contrast; reserve the material for controls. The memorable feature is a quiet, tactile action shelf, not multiple decorated panels.

## Upstream localization integration

Merged origin/main at 570a200. Preserved upstream L(), AppLanguage persistence, system/zh-Hant/en choices, resource copying and development-region metadata. All new interface strings, dynamic format strings, tooltips, panel prompts and accessibility labels have English translations. Native language names remain in their own language. Runtime bundle tests cover both explicit languages and system fallback.

## Verification

- Built the native arm64 app with macOS 13 deployment target and macOS 26 availability guards.
- Inspected actual dark-mode screenshots of the empty workspace and mixed completed/failed queue.
- Used the actual Language picker to switch English → Traditional Chinese → English; new UI text updated without restarting. Existing stored job messages retain upstream's restart behavior.
- Used the native folder picker to import two disposable synthetic files. Both waited for Start. A 0.2-second clip converted successfully; an invalid fixture displayed a failure and Retry. Clear completed removed the success and preserved the failure. Removed test rows afterward.
- Found English copy could push language selection below the fold; pinned Language below the inspector's scroll area.
- Verified normal H.264/AAC remux and MPEG-2/MP2 → H.264/AAC re-encode outputs with ffprobe.
- Regression suite covers original output-safety fixes, live model notifications, completed-only clearing, protected probing entries and localization bundle lookup.
- Independent standards/spec review found one wording issue: the checkbox controls video re-encoding while audio repair remains automatic. Corrected both languages and helper text.

Remaining checks: runtime appearance on macOS 13–15, light mode, VoiceOver narration and physical exFAT/FAT32 output volumes. No user media was used. No installation or remote push was performed.

## Primary action contrast correction

Replaced the system prominent-button rendering inside the glass shelf with an explicit native ButtonStyle: opaque white semibold label and arrow over a solid deep-blue capsule. The specified enabled colors have a calculated contrast ratio of 5.87:1. Disabled state uses a neutral system surface and readable grey text instead of reducing the opacity of the entire button. Inspected both states in the running app using a disposable waiting fixture, then removed it from the queue. Build and existing regression suite passed.

## Free / Pro appearance controls

Keep the existing native palette: workspace #F4F6F9, content #FFFFFF, ink #1D2433, secondary #687385, accent #2670E8; use semantic system equivalents so Pro dark mode follows native surfaces. SF system type remains unchanged. A small 11 pt capsule beside the app title identifies the edition: neutral Free, blue Pro. No crown, gradient or purchase popover on launch.

Appearance lives above Language in the inspector and opens one panel with Light, Dark and System rows. Free always uses Light, including when macOS or a saved Pro preference is dark. Dark and System remain visible with locks; selecting one explains the Pro feature without changing the workspace. Pro changes apply immediately, persist across launches, and System delegates switching to macOS. Native file panels use the same effective appearance. A revoked entitlement immediately returns to Light while preserving the Pro preference for later restoration.

Production starts Free. AppAccess is an injectable entitlement boundary, not a payment verifier; no tier is trusted from UserDefaults or environment variables. A future verified license provider may update it. Developer Pro previews require the explicit MACMP4_PREVIEW_PRO compiler flag; the release build script never enables it. The panel states Pro upgrades are coming soon, since purchase and serial activation are outside this change.

### Appearance verification (2026-10-16)

- arm64 build and all regressions passed, including 157 localized English keys.
- Isolated Free app: badge and Light inspector label visible, Traditional Chinese language switch works, clicking Dark shows the Pro explanation and leaves Light selected.
- Isolated compile-time Pro preview: badge visible, Light/Dark/System each selected successfully, Dark sheet visually inspected. No user system appearance setting changed.
- Preferences tested in isolated UserDefaults domains: persistence, invalid-value fallback, Free rejection of dark/system, entitlement revocation/restoration, and no unlock through unrelated isPro/tier defaults.
- Payment, serial/email validation and automatic paid activation are not implemented in this change. Existing v1 release and installed application are unchanged.

## Force H.264 and Super Thanks

Force H.264 is an opt-in Advanced option, off on every fresh JobStore. It skips stream-copy paths, takes precedence over the normal fallback re-encode toggle, and validates H.264/AAC before committing output. CPU and VideoToolbox fallback order and all existing output-protection/skip rules remain unchanged. Conversion is available to Free and Pro. Per owner request, the UI does not add a quality-loss warning; output format and original-file preservation are stated directly.

The support entry is named 超級感謝 / Super Thanks. Its native heart silhouette has a dollar-sign cutout, matching the supplied reference direction and adapting to either appearance. A compact inspector entry opens a Pro summary with the agreed NT$90 lifetime price and honest coming-soon payment status. No checkout or fake activation is added.

Verification: arm64 GUI/CLI build and all regressions passed (171 English keys). Synthetic HEVC/AAC input remains HEVC by default; forced CPU and automatic hardware/fallback output both probe as H.264/AAC. The actual GUI model was tested with Force H.264 enabled and normal re-encoding disabled. Native UI inspection confirmed the checkbox starts off, enables the H.264/AAC labels, disables the redundant fallback checkbox, and returns to default when turned off. The Super Thanks entry and heart/dollar cutout were visually inspected in the running Traditional Chinese Free preview. No public release, website deployment or installed-app replacement was performed for this change.

Copyright, Super Thanks and About & License share one compact row in the inspector footer. Super Thanks is red for Free and secondary gray for Pro. Language remains directly beneath Appearance.


## Basic trimming — advanced opt-in

Preserve the established system palette (#F4F6F9 workspace, #FFFFFF content, #1D2433 ink, #687385 secondary, #2670E8 accent), SF type and left-aligned inspector. Inside the collapsed Advanced section, one checkbox reveals two labeled seconds fields (start / end), including decimal input and inline validation. No new toolbar, timeline or editing workspace. The existing glass action shelf remains the primary action.

Trimming is off by default and available in both editions. Enabling it explicitly requests H.264/AAC re-encoding of the retained region and disables redundant codec/fallback controls while retaining their preferences. Hardware acceleration remains selectable. The description states batch scope and `_trimmed.mp4` naming; source MP4/M4V files may now be trimmed without changing their default skip rule. Invalid numeric settings disable Start; duration errors fail only the affected file. Settings are frozen during conversion and trim values are snapshotted at batch start. Existing output transaction protection is reused.

The retained duration drives progress. ffmpeg uses output seeking (decode/discard before the cut, including unindexed long-GOP TS) plus an output duration limit; copied chapters are omitted because their original timestamps may fall outside the edit. Outputs must pass H.264/AAC validation and retained-duration tolerance before commit. FFmpeg option reference: https://ffmpeg.org/ffmpeg.html#Main-options

Verification (2026-10-22): final arm64 GUI/CLI build and the complete regression suite passed (181 English keys). Synthetic MP4, MKV and long-GOP TS fixtures verified actual retained first/last frame content, head-only/tail-only/both cuts, subsecond output, H.264/AAC, hardware/fallback paths, invalid input/durations, batch trim snapshots, no-overwrite, cancellation and rejection of an uncut output. Existing default remux, repair, output preservation, installer and appearance regressions passed. Separate CLI H.264/AAC remux and MPEG-2/MP2 CPU fallback both succeeded.

Native UI inspection covered English and Traditional Chinese, decimal fields, inline validation, off-by-default after reopening, and returning to the default output summary after disabling trimming. The final isolated Free preview imported a six-second synthetic TS through the native file picker, removed 2.2 seconds at each end, and completed using VideoToolbox. ffprobe confirmed H.264/AAC and 1.633333 seconds; the first retained frame was green as expected. Screenshot: `/Users/jimmy/Desktop/Codex/outputs/MacMP4-trim-options.jpg`. No user media, installed-app replacement, remote push or public release was involved. Older macOS runtime and VoiceOver narration remain unverified.
