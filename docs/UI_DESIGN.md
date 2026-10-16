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
