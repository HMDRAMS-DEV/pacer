// Renders Pacer's app icon into the asset catalog, plus light and dark copies for the website.
//
//     swift scripts/render-icon.swift
//
// The mark is the dot chart reduced to its idea: dots filling up the week from the bottom left,
// with the finish as a ring in the top right corner. It sits well inside the tile.

import AppKit

let output = URL(fileURLWithPath: "Pacer/Assets.xcassets/AppIcon.appiconset")
let site = URL(fileURLWithPath: "site/assets")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: nil)!
}

func draw(in context: CGContext, size: CGFloat, dark: Bool) {
    let scale = size / 1024
    context.scaleBy(x: scale, y: scale)

    // The macOS icon grid: an 824pt rounded square centered on a 1024pt canvas, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.3))
    context.addPath(shape)
    context.setFillColor(color(dark ? 0x161618 : 0xF7F5F3))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = dark ? gradient([color(0x2A2A2E), color(0x0E0E10)]) : gradient([color(0xFFFFFF), color(0xEEEAE5)])
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.restoreGState()

    // A hairline inner edge, so the tile holds its shape on a desktop of the same shade.
    context.saveGState()
    context.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 183, cornerHeight: 183, transform: nil))
    context.setStrokeColor(dark ? color(0xFFFFFF, 0.08) : color(0x000000, 0.06))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()

    // A 3 x 3 grid of outline dots in the middle of the tile, with wide margins on every side.
    // Filled dots climb from the bottom left; the top right is the finish, a bold ring.
    let pitch: CGFloat = 150, diameter: CGFloat = 104, line: CGFloat = 13
    let filled: Set<[Int]> = [[0, 0], [1, 0], [1, 1], [2, 0], [2, 1]]
    for column in 0..<3 {
        for row in 0..<3 {
            let center = CGPoint(x: 512 + pitch * CGFloat(column - 1), y: 512 + pitch * CGFloat(row - 1))
            let rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            if column == 2 && row == 2 {
                context.setStrokeColor(dark ? color(0xFFFFFF) : color(0x0D0D0D))
                context.setLineWidth(line * 1.7)
                context.strokeEllipse(in: rect.insetBy(dx: line * 0.85, dy: line * 0.85))
            } else if filled.contains([column, row]) {
                context.saveGState()
                context.addEllipse(in: rect)
                context.clip()
                context.drawLinearGradient(gradient([color(0x2F7BFF), color(0x6CB8FF)]), start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
                context.restoreGState()
            } else {
                context.setStrokeColor(dark ? color(0xFFFFFF, 0.2) : color(0x0D0D0D, 0.14))
                context.setLineWidth(line)
                context.strokeEllipse(in: rect.insetBy(dx: line / 2, dy: line / 2))
            }
        }
    }
}

func png(pixels: Int, dark: Bool = false) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    draw(in: context.cgContext, size: CGFloat(pixels), dark: dark)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(pixels: points * scale).write(to: output.appending(path: name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appending(path: "Contents.json"))
print("Wrote \(images.count) icons to \(output.path)")

try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
for dark in [false, true] {
    let suffix = dark ? "-dark" : ""
    try png(pixels: 512, dark: dark).write(to: site.appending(path: "icon\(suffix).png"))
    try png(pixels: 64, dark: dark).write(to: site.appending(path: "favicon\(suffix).png"))
}
print("Wrote light and dark icons to \(site.path)")
