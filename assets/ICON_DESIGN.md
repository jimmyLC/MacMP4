# MacMP4 icon — reference-led exchange mark

The user's supplied reference is a thin blue pair of horizontal arrows pointing in opposite directions, upper left and lower right. The final direction preserves that recognizability while adjusting equal stroke weights, 45-degree heads, spacing and round caps. The deep graphite glass-like tile has a restrained highlight; the mark remains crisp and legible.

`makeicon.swift` is the editable native drawing source, replacing the discarded generated illustrations. `AppIcon.png` is its 1024 px preview. `Mark.svg` is an editable vector companion; SwiftUI uses a matching native Shape in its header. No external bitmap or image generation service is needed to rebuild this revision.

Regenerate with `swift assets/makeicon.swift assets/AppIcon.png`, then `./build.sh` for the full iconset and icns. The optional size argument uses slightly heavier strokes for directly rendered small sizes.

This is a static icon with glass-inspired styling. The app itself uses native SwiftUI glassEffect on macOS 26+ and system material on older macOS releases.

The user requested a dark background. The tile uses graphite #303239 → #23252B → #17191E, with subtle edge highlights. The blue arrow geometry and colors are preserved.
