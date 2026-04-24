#!/usr/bin/env swift
import Foundation
import SwiftUI
import AppKit

/// OrbitTerm 品牌 Logo 视图：深空背景 + 轨道环 + 中心核心。
struct OrbitLogoView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.09, blue: 0.22),
                    Color(red: 0.01, green: 0.02, blue: 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.29, green: 0.64, blue: 1.00),
                            Color(red: 0.48, green: 0.86, blue: 1.00)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 56
                )
                .frame(width: 680, height: 680)
                .shadow(color: Color.blue.opacity(0.35), radius: 36, x: 0, y: 12)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            Color(red: 0.31, green: 0.67, blue: 1.0)
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: 180
                    )
                )
                .frame(width: 300, height: 300)
                .overlay(
                    Text("OT")
                        .font(.system(size: 140, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(red: 0.04, green: 0.10, blue: 0.28))
                )
                .shadow(color: Color.cyan.opacity(0.25), radius: 22, x: 0, y: 8)
        }
    }
}

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

func renderPNG(side: Int) async throws -> Data {
    try await MainActor.run {
        let rendererScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
        let view = OrbitLogoView().frame(width: CGFloat(side), height: CGFloat(side))
        let renderer = ImageRenderer(content: view)
        renderer.scale = rendererScale
        renderer.proposedSize = ProposedViewSize(CGSize(width: CGFloat(side), height: CGFloat(side)))

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            struct RenderError: Error {}
            throw RenderError()
        }
        return png
    }
}

let appRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetDir = appRoot
    .appendingPathComponent("OrbitTerm/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

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
    let png = try await renderPNG(side: side)
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
