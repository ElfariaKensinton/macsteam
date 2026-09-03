#!/usr/bin/env swift
// Generates AppIcon.icns: an SF Symbol on a gradient squircle, rendered at each
// iconset size then packed via `iconutil`. Run: swift make_icon.swift
import AppKit

let symbolName = "shippingbox.fill"   // depot/manifest ZIP packages
let outIconset = "AppIcon.iconset"
let outIcns    = "AppIcon.icns"

// Apple's "continuous" corner radius for macOS icons is ~22.37% of the icon's
// full canvas. macOS icons also leave padding around the rounded tile.
func makeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    // Tile occupies ~82% of the canvas, centered (matches macOS icon grid).
    let tileInset = size * 0.09
    let tileRect = CGRect(x: tileInset, y: tileInset,
                          width: size - tileInset * 2,
                          height: size - tileInset * 2)
    let radius = tileRect.width * 0.2237
    let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: radius, yRadius: radius)

    // Steam-ish deep blue gradient.
    let top    = NSColor(calibratedRed: 0.13, green: 0.20, blue: 0.29, alpha: 1.0) // #212F4A-ish
    let bottom = NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.16, alpha: 1.0) // #0F1A29-ish
    ctx.saveGState()
    tilePath.addClip()
    let gradient = NSGradient(starting: top, ending: bottom)!
    gradient.draw(in: tileRect, angle: -90)
    ctx.restoreGState()

    // Subtle top highlight for depth.
    ctx.saveGState()
    tilePath.addClip()
    let hl = NSColor(white: 1.0, alpha: 0.06)
    hl.setFill()
    let hlRect = CGRect(x: tileRect.minX, y: tileRect.midY,
                        width: tileRect.width, height: tileRect.height / 2)
    NSBezierPath(rect: hlRect).fill()
    ctx.restoreGState()

    // SF Symbol glyph, white, centered, ~52% of tile.
    let cfg = NSImage.SymbolConfiguration(pointSize: tileRect.width * 0.52, weight: .semibold)
    if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size)
        tinted.lockFocus()
        sym.draw(at: .zero, from: NSRect(origin: .zero, size: sym.size),
                 operation: .sourceOver, fraction: 1.0)
        NSColor.white.set()
        NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let gw = sym.size.width, gh = sym.size.height
        let gx = tileRect.midX - gw / 2
        let gy = tileRect.midY - gh / 2
        tinted.draw(at: NSPoint(x: gx, y: gy),
                    from: NSRect(origin: .zero, size: sym.size),
                    operation: .sourceOver, fraction: 1.0)
    }

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to path: String, pixels: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .calibratedRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
try? fm.removeItem(atPath: outIconset)
try! fm.createDirectory(atPath: outIconset, withIntermediateDirectories: true)

// (base point size, @1x filename, @2x filename)
let entries: [(Int, String, String?)] = [
    (16,  "icon_16x16.png",   "icon_16x16@2x.png"),
    (32,  "icon_32x32.png",   "icon_32x32@2x.png"),
    (128, "icon_128x128.png", "icon_128x128@2x.png"),
    (256, "icon_256x256.png", "icon_256x256@2x.png"),
    (512, "icon_512x512.png", "icon_512x512@2x.png"),
]

for (base, name1x, name2x) in entries {
    let img1 = makeIcon(size: CGFloat(base))
    writePNG(img1, to: "\(outIconset)/\(name1x)", pixels: base)
    if let name2 = name2x {
        let img2 = makeIcon(size: CGFloat(base * 2))
        writePNG(img2, to: "\(outIconset)/\(name2)", pixels: base * 2)
    }
}

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", outIconset, "-o", outIcns]
task.launch()
task.waitUntilExit()
try? fm.removeItem(atPath: outIconset)
print(task.terminationStatus == 0 ? "Built \(outIcns)" : "iconutil failed (\(task.terminationStatus))")
