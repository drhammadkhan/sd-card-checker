// Renders the app icon into an .iconset folder. Usage: swift make_icon.swift <out.iconset>
import AppKit

let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.60, blue: 1.00, alpha: 1),
               ending: NSColor(calibratedRed: 0.09, green: 0.27, blue: 0.72, alpha: 1))!.draw(in: bg, angle: -90)

    let cardConfig = NSImage.SymbolConfiguration(pointSize: s * 0.44, weight: .regular)
        .applying(.init(paletteColors: [.white]))
    if let card = NSImage(systemSymbolName: "sdcard.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cardConfig) {
        let sz = card.size
        card.draw(in: NSRect(x: (s - sz.width) / 2 - s * 0.03, y: (s - sz.height) / 2 + s * 0.03, width: sz.width, height: sz.height))
    }
    // Green health badge
    let d = s * 0.30
    let badgeRect = NSRect(x: s * 0.58, y: s * 0.14, width: d, height: d)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: badgeRect.insetBy(dx: -s * 0.015, dy: -s * 0.015)).fill()
    NSColor(calibratedRed: 0.18, green: 0.75, blue: 0.35, alpha: 1).setFill()
    NSBezierPath(ovalIn: badgeRect).fill()
    let checkConfig = NSImage.SymbolConfiguration(pointSize: d * 0.5, weight: .bold).applying(.init(paletteColors: [.white]))
    if let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(checkConfig) {
        let sz = check.size
        check.draw(in: NSRect(x: badgeRect.midX - sz.width / 2, y: badgeRect.midY - sz.height / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base)@2x.png"))
}
