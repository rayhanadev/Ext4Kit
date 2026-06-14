#!/usr/bin/env swift
// Generates a placeholder app icon for Ext4Kit and writes the macOS icon
// set into Ext4Kit/Assets.xcassets/AppIcon.appiconset. Reproducible, so the
// PNGs can be regenerated (or swapped for real art) at any time.
//
//   swift Scripts/make-icon.swift
//
// Draws a gradient squircle with an external-drive glyph and an "ext4"
// wordmark — a clean stand-in until real branding exists.

import AppKit

let iconset = "Ext4Kit/Assets.xcassets/AppIcon.appiconset"
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    // Explicit pixel-exact bitmap — NSImage.lockFocus would render at the
    // screen's backing scale (2x on Retina) and double the dimensions.
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Transparent canvas; squircle inset (macOS icon grid leaves padding).
    let inset = s * 0.10
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = (s - 2 * inset) * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()

    // Indigo → blue gradient.
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.32, blue: 0.78, alpha: 1.0),
        NSColor(calibratedRed: 0.18, green: 0.49, blue: 0.86, alpha: 1.0),
    ])!
    grad.draw(in: rect, angle: -90)

    // Drive glyph.
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.30, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg)
    {
        let tinted = NSImage(size: sym.size)
        tinted.lockFocus()
        NSColor.white.withAlphaComponent(0.95).set()
        let r = CGRect(origin: .zero, size: sym.size)
        sym.draw(in: r)
        r.fill(using: .sourceAtop)
        tinted.unlockFocus()
        let gx = rect.midX - sym.size.width / 2
        let gy = rect.midY - sym.size.height / 2 + s * 0.08
        tinted.draw(in: CGRect(x: gx, y: gy, width: sym.size.width, height: sym.size.height))
    }

    // Wordmark.
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.17, weight: .heavy),
        .foregroundColor: NSColor.white,
        .paragraphStyle: para,
    ]
    let text = "ext4" as NSString
    let textSize = text.size(withAttributes: attrs)
    text.draw(
        in: CGRect(
            x: rect.minX, y: rect.minY + s * 0.12,
            width: rect.width, height: textSize.height),
        withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("render \(px) failed")
    }
    return png
}

var images: [[String: String]] = []
for px in sizes {
    let name = "icon_\(px).png"
    try! render(px).write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
    print("wrote \(name)")
}

// macOS AppIcon slots → file by pixel size.
let slots: [(String, String, Int)] = [
    ("16x16", "1x", 16), ("16x16", "2x", 32),
    ("32x32", "1x", 32), ("32x32", "2x", 64),
    ("128x128", "1x", 128), ("128x128", "2x", 256),
    ("256x256", "1x", 256), ("256x256", "2x", 512),
    ("512x512", "1x", 512), ("512x512", "2x", 1024),
]
for (size, scale, px) in slots {
    images.append(["idiom": "mac", "size": size, "scale": scale, "filename": "icon_\(px).png"])
}
let contents: [String: Any] = [
    "images": images,
    "info": ["version": 1, "author": "ext4kit-make-icon"],
]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: "\(iconset)/Contents.json"))
print("wrote Contents.json")
