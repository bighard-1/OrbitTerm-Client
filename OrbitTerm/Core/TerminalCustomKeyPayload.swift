import Foundation

/// v1 byte grammar: UTF-8 literals and \\t/\\r/\\n/\\e/\\\\/\\xNN. No shell expansion.
enum TerminalCustomKeyPayload {
    static func decode(_ payload: String) -> [UInt8]? {
        guard !payload.isEmpty, payload.utf8.count <= 256 else { return nil }
        let input = Array(payload.utf8)
        var output: [UInt8] = []
        var index = 0
        while index < input.count {
            let byte = input[index]
            index += 1
            if byte != 92 {
                output.append(byte)
            } else {
                guard index < input.count else { return nil }
                let escape = input[index]
                index += 1
                switch escape {
                case 116: output.append(9)
                case 114: output.append(13)
                case 110: output.append(10)
                case 101: output.append(27)
                case 92: output.append(92)
                case 120:
                    guard index + 1 < input.count,
                          let high = hex(input[index]), let low = hex(input[index + 1]) else { return nil }
                    output.append(high * 16 + low)
                    index += 2
                default: return nil
                }
            }
            guard output.count <= 64 else { return nil }
        }
        return output
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 65 + 10
        case 97...102: byte - 97 + 10
        default: nil
        }
    }
}
