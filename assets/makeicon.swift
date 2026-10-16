// makeicon.swift — 產生 1024x1024 App 圖示 PNG(Apple Big Sur 風格)
// 用法: swift makeicon.swift <輸出.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S: CGFloat = 1024
let M: CGFloat = 100          // 邊距 → 內容 824x824(macOS 標準網格)
let R: CGFloat = 185          // 圓角(≈ macOS 標準 squircle)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// MARK: 背景 — 中性灰漸層 squircle

let rect = NSRect(x: M, y: M, width: S - M * 2, height: S - M * 2)
let squircle = NSBezierPath(roundedRect: rect, xRadius: R, yRadius: R)

let bg = NSGradient(colors: [
    NSColor(calibratedRed: 0.965, green: 0.965, blue: 0.973, alpha: 1),  // #F6F6F8 左上
    NSColor(calibratedRed: 0.812, green: 0.812, blue: 0.835, alpha: 1),  // #CFCFD5 右下
])!
bg.draw(in: squircle, angle: -50)

// 底部內陰影,增加立體感
if let shade = NSGradient(colorsAndLocations:
    (NSColor.black.withAlphaComponent(0.0), 0.30),
    (NSColor.black.withAlphaComponent(0.06), 1.0)
) {
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    shade.draw(in: rect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

// 上緣內高光(整面漸層自然淡出,避免接縫)
if let sheen = NSGradient(colorsAndLocations:
    (NSColor.white.withAlphaComponent(0.55), 0.0),
    (NSColor.white.withAlphaComponent(0.10), 0.38),
    (NSColor.white.withAlphaComponent(0.0), 0.75)
) {
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    sheen.draw(in: rect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

// 極細外框,讓邊界更俐落
NSColor.black.withAlphaComponent(0.08).setStroke()
squircle.lineWidth = 2
squircle.stroke()

// MARK: 播放鍵 — 石墨色圓角三角

let cx = S / 2
let cy = S * 0.615
let p1 = CGPoint(x: cx - 172, y: cy + 183)
let p2 = CGPoint(x: cx + 212, y: cy)
let p3 = CGPoint(x: cx - 172, y: cy - 183)

func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
}

let cg = CGMutablePath()
cg.move(to: mid(p1, p2))
cg.addArc(tangent1End: p2, tangent2End: p3, radius: 36)
cg.addArc(tangent1End: p3, tangent2End: p1, radius: 36)
cg.addArc(tangent1End: p1, tangent2End: p2, radius: 36)
cg.closeSubpath()
let tri = NSBezierPath(cgPath: cg)

let shadow = NSShadow()
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
shadow.set()

let fg = NSGradient(colors: [
    NSColor(calibratedRed: 0.255, green: 0.255, blue: 0.290, alpha: 1),  // #41414A 上
    NSColor(calibratedRed: 0.125, green: 0.125, blue: 0.145, alpha: 1),  // #202025 下
])!
fg.draw(in: tri, angle: 90)

// MARK: MP4 — SF Rounded 字型

// 清除三角形留下的陰影狀態,文字保持俐落
NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

var font = NSFont.systemFont(ofSize: 152, weight: .heavy)
if let desc = font.fontDescriptor.withDesign(.rounded),
   let rounded = NSFont(descriptor: desc, size: 152) {
    font = rounded
}
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.18, alpha: 1),  // #29292E
]
let text = "MP4" as NSString
let ts = text.size(withAttributes: attrs)
text.draw(at: NSPoint(x: (S - ts.width) / 2, y: S * 0.145), withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try? png.write(to: URL(fileURLWithPath: outPath))
