// Draw a 1024×1024 app icon programmatically and write it out as a PNG.
// Usage: swift icon.swift <output_path.png>
// Design: blue gradient squircle (macOS Big Sur style) with white bidirectional arrows (transfer) overlaid.
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("Cannot create bitmap") }

NSGraphicsContext.saveGraphicsState()
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("Cannot create context") }
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

// --- Background squircle (rounded corners + margin for a floating feel) ---
let margin: CGFloat = 92
let rect = NSRect(x: margin, y: margin,
                  width: CGFloat(size) - 2 * margin,
                  height: CGFloat(size) - 2 * margin)
let radius: CGFloat = 188 // corner-radius / width ≈ 0.2237 (macOS icon grid)
let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// Drop a shadow first, then layer the gradient on top
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 30,
             color: NSColor.black.withAlphaComponent(0.25).cgColor)
NSColor(srgbRed: 0.09, green: 0.33, blue: 0.86, alpha: 1).setFill()
shape.fill()
cg.restoreGState()

let topColor = NSColor(srgbRed: 0.27, green: 0.56, blue: 0.99, alpha: 1)
let bottomColor = NSColor(srgbRed: 0.09, green: 0.33, blue: 0.86, alpha: 1)
if let gradient = NSGradient(starting: topColor, ending: bottomColor) {
    gradient.draw(in: shape, angle: -90) // top to bottom
}

// --- White bidirectional arrows (transfer) ---
NSColor.white.setFill()
NSColor.white.setStroke()

// Top arrow (pointing right)
let topShaft = NSBezierPath()
topShaft.move(to: NSPoint(x: 340, y: 590))
topShaft.line(to: NSPoint(x: 612, y: 590))
topShaft.lineWidth = 60
topShaft.lineCapStyle = .round
topShaft.stroke()

let topHead = NSBezierPath()
topHead.move(to: NSPoint(x: 708, y: 590))
topHead.line(to: NSPoint(x: 600, y: 535))
topHead.line(to: NSPoint(x: 600, y: 645))
topHead.close()
topHead.fill()

// Bottom arrow (pointing left, vertically symmetric)
let botShaft = NSBezierPath()
botShaft.move(to: NSPoint(x: 684, y: 434))
botShaft.line(to: NSPoint(x: 412, y: 434))
botShaft.lineWidth = 60
botShaft.lineCapStyle = .round
botShaft.stroke()

let botHead = NSBezierPath()
botHead.move(to: NSPoint(x: 316, y: 434))
botHead.line(to: NSPoint(x: 424, y: 379))
botHead.line(to: NSPoint(x: 424, y: 489))
botHead.close()
botHead.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Cannot convert to PNG")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("✓ Wrote: \(outPath)")
