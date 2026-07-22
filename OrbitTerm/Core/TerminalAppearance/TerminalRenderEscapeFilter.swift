import Foundation

/// Removes only the CSI window-manipulation commands that SwiftTerm 1.11.2
/// cannot safely handle on macOS. The filter sits at the rendering boundary:
/// remote bytes and terminal input are never changed.
struct TerminalRenderEscapeFilter {
    private enum State {
        case normal
        case escape
        case csi
    }

    private static let escape: UInt8 = 0x1B
    private static let csiIntroducer: UInt8 = 0x5B
    private static let windowCommand: UInt8 = 0x74
    private static let maxSequenceLength = 256

    private var state: State = .normal
    private var pending: [UInt8] = []

    mutating func filter(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count)

        for byte in input {
            switch state {
            case .normal:
                if byte == Self.escape {
                    pending = [byte]
                    state = .escape
                } else {
                    output.append(byte)
                }

            case .escape:
                pending.append(byte)
                if byte == Self.csiIntroducer {
                    state = .csi
                } else {
                    output.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                    state = .normal
                }

            case .csi:
                pending.append(byte)
                if pending.count > Self.maxSequenceLength {
                    output.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                    state = .normal
                } else if (0x40 ... 0x7E).contains(byte) {
                    if byte != Self.windowCommand {
                        output.append(contentsOf: pending)
                    }
                    pending.removeAll(keepingCapacity: true)
                    state = .normal
                }
            }
        }

        return output
    }

    mutating func reset() {
        state = .normal
        pending.removeAll(keepingCapacity: false)
    }
}
