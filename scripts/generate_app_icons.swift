#!/usr/bin/env swift
import Foundation
import AppKit

struct IconSpec {
    let idiom: String
    let size: String
    let scale: String
    let filename: String
}

func pixelLength(size: String, scale: String) -> Int {
    let baseSide = size.split(separator: "x").first.flatMap { Double($0) } ?? 1024
    let multiplier = Double(scale.dropLast()) ?? 1
    return Int((baseSide * multiplier).rounded())
}

let appRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetDir = appRoot
    .appendingPathComponent("OrbitTerm/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let sourceLogoURL = appRoot
    .appendingPathComponent("OrbitTerm/Assets.xcassets/OrbitTermLogo.imageset/orbitterm-logo-1024.png")

guard let sourceLogo = NSImage(contentsOf: sourceLogoURL) else {
    throw NSError(
        domain: "icon.render",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Missing canonical OrbitTerm logo at \(sourceLogoURL.path)"]
    )
}

func renderPNG(side: Int) throws -> Data {
    let targetSize = NSSize(width: side, height: side)
    let image = NSImage(size: targetSize)
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    sourceLogo.draw(
        in: NSRect(origin: .zero, size: targetSize),
        from: NSRect(origin: .zero, size: sourceLogo.size),
        operation: .sourceOver,
        fraction: 1
    )
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon.render", code: 2)
    }
    return png
}

try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let specs: [IconSpec] = [
    .init(idiom: "iphone", size: "20x20", scale: "2x", filename: "iphone-20@2x.png"),
    .init(idiom: "iphone", size: "20x20", scale: "3x", filename: "iphone-20@3x.png"),
    .init(idiom: "iphone", size: "29x29", scale: "2x", filename: "iphone-29@2x.png"),
    .init(idiom: "iphone", size: "29x29", scale: "3x", filename: "iphone-29@3x.png"),
    .init(idiom: "iphone", size: "40x40", scale: "2x", filename: "iphone-40@2x.png"),
    .init(idiom: "iphone", size: "40x40", scale: "3x", filename: "iphone-40@3x.png"),
    .init(idiom: "iphone", size: "60x60", scale: "2x", filename: "iphone-60@2x.png"),
    .init(idiom: "iphone", size: "60x60", scale: "3x", filename: "iphone-60@3x.png"),

    .init(idiom: "ipad", size: "20x20", scale: "1x", filename: "ipad-20@1x.png"),
    .init(idiom: "ipad", size: "20x20", scale: "2x", filename: "ipad-20@2x.png"),
    .init(idiom: "ipad", size: "29x29", scale: "1x", filename: "ipad-29@1x.png"),
    .init(idiom: "ipad", size: "29x29", scale: "2x", filename: "ipad-29@2x.png"),
    .init(idiom: "ipad", size: "40x40", scale: "1x", filename: "ipad-40@1x.png"),
    .init(idiom: "ipad", size: "40x40", scale: "2x", filename: "ipad-40@2x.png"),
    .init(idiom: "ipad", size: "76x76", scale: "1x", filename: "ipad-76@1x.png"),
    .init(idiom: "ipad", size: "76x76", scale: "2x", filename: "ipad-76@2x.png"),
    .init(idiom: "ipad", size: "83.5x83.5", scale: "2x", filename: "ipad-83_5@2x.png"),

    .init(idiom: "ios-marketing", size: "1024x1024", scale: "1x", filename: "ios-marketing-1024.png"),

    .init(idiom: "mac", size: "16x16", scale: "1x", filename: "mac-16@1x.png"),
    .init(idiom: "mac", size: "16x16", scale: "2x", filename: "mac-16@2x.png"),
    .init(idiom: "mac", size: "32x32", scale: "1x", filename: "mac-32@1x.png"),
    .init(idiom: "mac", size: "32x32", scale: "2x", filename: "mac-32@2x.png"),
    .init(idiom: "mac", size: "128x128", scale: "1x", filename: "mac-128@1x.png"),
    .init(idiom: "mac", size: "128x128", scale: "2x", filename: "mac-128@2x.png"),
    .init(idiom: "mac", size: "256x256", scale: "1x", filename: "mac-256@1x.png"),
    .init(idiom: "mac", size: "256x256", scale: "2x", filename: "mac-256@2x.png"),
    .init(idiom: "mac", size: "512x512", scale: "1x", filename: "mac-512@1x.png"),
    .init(idiom: "mac", size: "512x512", scale: "2x", filename: "mac-512@2x.png")
]

for spec in specs {
    let side = pixelLength(size: spec.size, scale: spec.scale)
    let png = try renderPNG(side: side)
    try png.write(to: iconsetDir.appendingPathComponent(spec.filename))
}

let images = specs.map { spec in
    [
        "idiom": spec.idiom,
        "size": spec.size,
        "scale": spec.scale,
        "filename": spec.filename
    ]
}

let payload: [String: Any] = [
    "images": images,
    "info": [
        "author": "xcode",
        "version": 1
    ]
]
let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
try jsonData.write(to: iconsetDir.appendingPathComponent("Contents.json"))

print("[完成] AppIcon 已生成到: \(iconsetDir.path)")
