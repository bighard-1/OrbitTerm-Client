#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import SwiftUI

enum RemoteDesktopFrameError: Error, Equatable {
    case invalidDimensions
    case invalidStride
    case insufficientBytes
    case imageCreationFailed
}

struct RemoteDesktopFrame: Sendable {
    static let maximumDimension = 16_384

    let width: Int
    let height: Int
    let stride: Int
    let bgraBytes: Data

    init(width: Int, height: Int, stride: Int, bgraBytes: Data) throws {
        guard width > 0, height > 0,
              width <= Self.maximumDimension, height <= Self.maximumDimension else {
            throw RemoteDesktopFrameError.invalidDimensions
        }
        guard stride >= width * 4 else { throw RemoteDesktopFrameError.invalidStride }
        let (requiredBytes, overflow) = stride.multipliedReportingOverflow(by: height)
        guard !overflow, bgraBytes.count >= requiredBytes else {
            throw RemoteDesktopFrameError.insufficientBytes
        }
        self.width = width
        self.height = height
        self.stride = stride
        self.bgraBytes = bgraBytes
    }

    func makeImage() throws -> CGImage {
        guard let provider = CGDataProvider(data: bgraBytes as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: stride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
                    .union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw RemoteDesktopFrameError.imageCreationFailed
        }
        return image
    }
}

@MainActor
final class FreeRDPFrameBufferModel: ObservableObject {
    @Published private(set) var image: CGImage?

    func publish(_ frame: RemoteDesktopFrame) throws {
        image = try frame.makeImage()
    }

    func clear() {
        image = nil
    }
}

final class FreeRDPNativeDesktopView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }

        let sourceSize = CGSize(width: image.width, height: image.height)
        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        let targetSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let target = CGRect(
            x: (bounds.width - targetSize.width) / 2,
            y: (bounds.height - targetSize.height) / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        context.interpolationQuality = .none
        context.draw(image, in: target)
    }
}

struct FreeRDPDesktopSurface: NSViewRepresentable {
    @ObservedObject var model: FreeRDPFrameBufferModel

    func makeNSView(context: Context) -> FreeRDPNativeDesktopView {
        let view = FreeRDPNativeDesktopView()
        view.image = model.image
        return view
    }

    func updateNSView(_ nsView: FreeRDPNativeDesktopView, context: Context) {
        nsView.image = model.image
    }
}
#endif
