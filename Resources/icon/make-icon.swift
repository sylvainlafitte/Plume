// Regenerates Resources/AppIcon.icns. The .icns is committed — this exists so
// the artwork is editable as code rather than as an opaque binary:
//
//   swift Resources/icon/make-icon.swift /tmp/AppIcon.iconset
//   iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
//
// The feather is the same Lucide path the menu-bar item draws
// (MenuBarController.featherSVG); keep the two in step.
import AppKit

let featherSVG = """
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"
viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="1.35"
stroke-linecap="round" stroke-linejoin="round">
<path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>
<path d="M16 8 2 22"/>
<path d="M17.5 15H9"/>
</svg>
"""

func squircle(_ r: NSRect) -> NSBezierPath {
    // Apple's app-icon corner is ~22.37% of the side.
    NSBezierPath(roundedRect: r, xRadius: r.width * 0.2237, yRadius: r.width * 0.2237)
}

func render(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    // The icon leaves a margin so the squircle matches the platform grid
    // (824/1024) instead of filling the canvas edge to edge.
    let inset = size * 0.098
    let box = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

    ctx.saveGState()
    squircle(box).addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.24, green: 0.30, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.09, blue: 0.18, alpha: 1),
    ])!.draw(in: box, angle: -90)
    // A soft warm glow behind the quill, so the mark reads as ink on a lit page
    // rather than a flat plate at small sizes. Kept low-alpha and off-centre:
    // any stronger and it greys the blue out into brown.
    NSGradient(colors: [
        NSColor(srgbRed: 1.0, green: 0.76, blue: 0.45, alpha: 0.16),
        NSColor(srgbRed: 1.0, green: 0.76, blue: 0.45, alpha: 0.0),
    ])!.draw(in: box.insetBy(dx: -box.width * 0.25, dy: -box.height * 0.25),
             relativeCenterPosition: NSPoint(x: -0.35, y: 0.45))
    ctx.restoreGState()

    // Top edge highlight — the standard macOS bevel cue.
    let rim = squircle(box.insetBy(dx: size * 0.004, dy: size * 0.004))
    rim.lineWidth = size * 0.008
    NSColor(white: 1, alpha: 0.16).setStroke()
    rim.stroke()

    if let feather = NSImage(data: featherSVG.data(using: .utf8)!) {
        let side = size * 0.56
        let rect = NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
        feather.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    img.unlockFocus()
    return img
}

let out = CommandLine.arguments[1]
try! FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                   (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                   (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let img = render(size: CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("ok")
