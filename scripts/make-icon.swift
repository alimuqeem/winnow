// Turns a square icon render (tile on a light background) into a macOS
// AppIcon.appiconset: crops the tile, masks it to Apple's 824 px rounded tile
// on a transparent 1024 canvas, and writes every required size.
//
//   swift scripts/make-icon.swift <source.png> <AppIcon.appiconset dir>
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: make-icon <source.png> <AppIcon.appiconset>"); exit(1)
}
let out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// 1. Read pixels and find the tile: rows/columns where most pixels are not light.
let w = cg.width, h = cg.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
func dark(_ x: Int, _ y: Int) -> Bool {
    let i = (y * w + x) * 4
    return Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) < 450   // the tile is teal/navy; background ~white
}
func span(_ count: Int, _ dim: Int, _ isDark: (Int, Int) -> Bool) -> (Int, Int) {
    var first = -1, last = -1
    for a in 0..<count {
        var n = 0
        for b in stride(from: 0, to: dim, by: 4) where isDark(a, b) { n += 1 }
        if n > dim / 4 / 3 { if first < 0 { first = a }; last = a }
    }
    return (first, last)
}
let (x0, x1) = span(w, h) { x, y in dark(x, y) }
let (y0, y1) = span(h, w) { y, x in dark(x, y) }
print("tile bbox x \(x0)...\(x1) y \(y0)...\(y1) (image \(w)x\(h))")
// The tile is square; a light glass highlight can hide its top edge from the
// threshold, so derive the top from the width and the (reliable) bottom edge.
let side = x1 - x0 + 1
let top = max(0, y1 - side + 1)
print("using square tile x \(x0) top \(top) side \(side) (detected top \(y0))")
// Pixel rows above run top-down; CGImage cropping uses the same top-left origin.
let crop = cg.cropping(to: CGRect(x: x0, y: top, width: side, height: side))!

// 2. Apple grid: 1024 canvas, 824 tile, continuous corners (~22.37% radius).
func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let g = NSGraphicsContext.current!.cgContext
    g.interpolationQuality = .high
    let s = CGFloat(size) / 1024
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    // Inset the source a hair so the render's own light anti-aliased rim is clipped away.
    let path = NSBezierPath(roundedRect: tile, xRadius: 184 * s, yRadius: 184 * s)
    path.addClip()
    g.draw(crop, in: tile.insetBy(dx: -6 * s, dy: -6 * s))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try render(base * scale).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count) sizes to \(out.path)")
