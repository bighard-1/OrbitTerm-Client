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
    weak var engineSession: FreeRDPEngineSession?
    var onViewportResize: ((Int, Int) -> Void)?
    private var tracking: NSTrackingArea?
    private var activeModifiers: NSEvent.ModifierFlags = []

    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let backing = convertToBacking(NSRect(origin: .zero, size: newSize)).size
        onViewportResize?(max(320, Int(backing.width)), max(200, Int(backing.height)))
    }

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

    override func mouseMoved(with event: NSEvent) { sendPointer(event, action: 0) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event, action: 0) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event, action: 0) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event, action: 0) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); sendPointer(event, action: 1) }
    override func mouseUp(with event: NSEvent) { sendPointer(event, action: 2) }
    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); sendPointer(event, action: 3) }
    override func rightMouseUp(with event: NSEvent) { sendPointer(event, action: 4) }
    override func otherMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); sendPointer(event, action: 5) }
    override func otherMouseUp(with event: NSEvent) { sendPointer(event, action: 6) }

    override func scrollWheel(with event: NSEvent) {
        guard let engineSession else { return }
        let location = remotePoint(for: event)
        let action: Int32 = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? 8 : 7
        let rawDelta = action == 8 ? event.scrollingDeltaX : event.scrollingDeltaY
        let delta = Int16(max(-120, min(120, Int(rawDelta * 12))))
        engineSession.sendPointer(action: action, x: location.x, y: location.y, wheelDelta: delta)
    }

    override func keyDown(with event: NSEvent) {
        if let scancode = Self.specialScancodes[event.keyCode] {
            engineSession?.send(scancode: scancode, pressed: true)
            return
        }
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {
        if let scancode = Self.specialScancodes[event.keyCode] {
            engineSession?.send(scancode: scancode, pressed: false)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let current = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mappings: [(NSEvent.ModifierFlags, UInt32)] = [
            (.shift, 0x2A),
            (.control, 0x1D),
            (.option, 0x38),
            (.command, 0x15B)
        ]
        for (flag, scancode) in mappings where current.contains(flag) != activeModifiers.contains(flag) {
            engineSession?.send(scancode: scancode, pressed: current.contains(flag))
        }
        if current.contains(.capsLock) != activeModifiers.contains(.capsLock) {
            engineSession?.send(scancode: 0x3A, pressed: true)
            engineSession?.send(scancode: 0x3A, pressed: false)
        }
        activeModifiers = current
    }

    override func insertText(_ insertString: Any) {
        let value: String
        if let attributed = insertString as? NSAttributedString { value = attributed.string }
        else { value = String(describing: insertString) }
        engineSession?.send(text: value)
    }

    private func sendPointer(_ event: NSEvent, action: Int32) {
        let point = remotePoint(for: event)
        engineSession?.sendPointer(action: action, x: point.x, y: point.y, wheelDelta: 0)
    }

    private func remotePoint(for event: NSEvent) -> (x: UInt16, y: UInt16) {
        guard let image else { return (0, 0) }
        let point = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let targetWidth = CGFloat(image.width) * scale
        let targetHeight = CGFloat(image.height) * scale
        let originX = (bounds.width - targetWidth) / 2
        let originY = (bounds.height - targetHeight) / 2
        let x = max(0, min(CGFloat(image.width - 1), (point.x - originX) / scale))
        let flippedY = targetHeight - (point.y - originY)
        let y = max(0, min(CGFloat(image.height - 1), flippedY / scale))
        return (UInt16(x), UInt16(y))
    }

    private static let specialScancodes: [UInt16: UInt32] = [
        36: 0x1C, // Return
        48: 0x0F, // Tab
        51: 0x0E, // Backspace
        53: 0x01, // Escape
        123: 0x14B, 124: 0x14D, 125: 0x150, 126: 0x148, // arrows
        115: 0x147, 119: 0x14F, 116: 0x149, 121: 0x151, // home/end/page
        117: 0x153, // forward delete
        122: 0x3B, 120: 0x3C, 99: 0x3D, 118: 0x3E, // F1-F4
        96: 0x3F, 97: 0x40, 98: 0x41, 100: 0x42, // F5-F8
        101: 0x43, 109: 0x44, 103: 0x57, 111: 0x58 // F9-F12
    ]
}

struct FreeRDPDesktopSurface: NSViewRepresentable {
    @ObservedObject var model: FreeRDPFrameBufferModel
    @ObservedObject var engineSession: FreeRDPEngineSession

    final class Coordinator {
        var pendingResize: DispatchWorkItem?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FreeRDPNativeDesktopView {
        let view = FreeRDPNativeDesktopView()
        view.image = model.image
        view.engineSession = engineSession
        view.onViewportResize = { [weak coordinator = context.coordinator, weak engineSession] width, height in
            coordinator?.pendingResize?.cancel()
            let work = DispatchWorkItem { [weak engineSession] in
                Task { @MainActor in await engineSession?.resize(width: width, height: height) }
            }
            coordinator?.pendingResize = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
        return view
    }

    func updateNSView(_ nsView: FreeRDPNativeDesktopView, context: Context) {
        nsView.image = model.image
        nsView.engineSession = engineSession
    }
}
#endif
