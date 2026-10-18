// SPDX-License-Identifier: GPL-3.0-only
// Deterministic native artwork. This tool renders source artwork; it does not
// compile or alter the app executable.
import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else { fatalError("Usage: swift draw_icon.swift OUTPUT.iconset") }
let output = URL(fileURLWithPath: arguments[0], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int, name: String) throws {
    let size = CGFloat(pixels)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
        pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot create icon bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let inset = size * 0.075
    let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset,
        width: size - inset * 2, height: size - inset * 2), xRadius: size * 0.19, yRadius: size * 0.19)
    NSGradient(starting: NSColor(calibratedWhite: 0.25, alpha: 1),
        ending: NSColor(calibratedWhite: 0.10, alpha: 1))!.draw(in: tile, angle: -90)
    NSColor(calibratedWhite: 0.65, alpha: 0.45).setStroke()
    tile.lineWidth = max(1, size * 0.006)
    tile.stroke()
    // Five meter bars echo the existing waveform menu-bar symbol.
    let heights: [CGFloat] = [0.20, 0.38, 0.56, 0.38, 0.20]
    let barWidth = size * 0.065
    for (index, height) in heights.enumerated() {
        let x = size * 0.27 + CGFloat(index) * size * 0.10
        let path = NSBezierPath(roundedRect: NSRect(x: x, y: (size - size * height) / 2,
            width: barWidth, height: size * height), xRadius: barWidth / 2, yRadius: barWidth / 2)
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.56, blue: 1, alpha: 1),
            ending: NSColor(calibratedRed: 0.18, green: 0.82, blue: 0.72, alpha: 1))!
            .draw(in: path, angle: 90)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode icon")
    }
    try png.write(to: output.appendingPathComponent(name))
}
for points in [16, 32, 128, 256, 512] {
    try render(points, name: "icon_\(points)x\(points).png")
    try render(points * 2, name: "icon_\(points)x\(points)@2x.png")
}
