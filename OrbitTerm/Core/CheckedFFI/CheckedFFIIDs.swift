import Foundation

enum CheckedFFIIDError: Error, Equatable, Sendable {
    case invalidDecimalID
    case invalidRequestID
}

private func canonicalDecimalID(_ rawValue: String) throws -> String {
    guard !rawValue.isEmpty,
          rawValue.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
          let value = UInt64(rawValue),
          value > 0 else {
        throw CheckedFFIIDError.invalidDecimalID
    }
    return String(value)
}

private extension CodingUserInfoKey {
    static let checkedNumericBaseSessionID = CodingUserInfoKey(
        rawValue: "com.orbitterm.checked-ffi.numeric-base-session-id"
    )!
}

struct BaseSessionID: Hashable, Sendable, Codable, CustomStringConvertible {
    let decimalString: String

    init(_ rawValue: String) throws {
        decimalString = try canonicalDecimalID(rawValue)
    }

    init(_ value: UInt64) throws {
        guard value > 0 else { throw CheckedFFIIDError.invalidDecimalID }
        decimalString = String(value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            try self.init(string)
            return
        }
        guard decoder.userInfo[.checkedNumericBaseSessionID] as? Bool == true else {
            throw CheckedFFIIDError.invalidDecimalID
        }
        let value = try container.decode(UInt64.self)
        try self.init(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(decimalString)
    }

    var ffiValue: UInt64 {
        // Construction proves the conversion is valid.
        UInt64(decimalString)!
    }

    var description: String { "base:\(decimalString)" }
}

enum CheckedFFIWireDecoder {
    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> Value {
        if type == BaseSessionID.self {
            try validateStandaloneBaseSessionID(in: data)
        } else {
            try validateNumericSessionIDTokens(in: data)
        }
        let previousValue = decoder.userInfo[.checkedNumericBaseSessionID]
        decoder.userInfo[.checkedNumericBaseSessionID] = true
        defer { decoder.userInfo[.checkedNumericBaseSessionID] = previousValue }
        return try decoder.decode(type, from: data)
    }

    private static func validateStandaloneBaseSessionID(in data: Data) throws {
        guard let json = String(data: data, encoding: .utf8) else {
            throw CheckedFFIIDError.invalidDecimalID
        }
        let token = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.first == "\"" {
            return
        }
        guard !token.isEmpty,
              token.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            throw CheckedFFIIDError.invalidDecimalID
        }
    }

    private static func validateNumericSessionIDTokens(in data: Data) throws {
        guard let json = String(data: data, encoding: .utf8) else {
            throw CheckedFFIIDError.invalidDecimalID
        }
        let key = "\"session_id\""
        var searchStart = json.startIndex

        while let range = json.range(of: key, range: searchStart ..< json.endIndex) {
            var index = range.upperBound
            skipWhitespace(in: json, index: &index)
            guard index < json.endIndex, json[index] == ":" else {
                throw CheckedFFIIDError.invalidDecimalID
            }
            index = json.index(after: index)
            skipWhitespace(in: json, index: &index)
            guard index < json.endIndex else {
                throw CheckedFFIIDError.invalidDecimalID
            }

            if json[index] != "\"" {
                let tokenStart = index
                while index < json.endIndex,
                      !json[index].isWhitespace,
                      json[index] != ",",
                      json[index] != "}" {
                    index = json.index(after: index)
                }
                let token = json[tokenStart ..< index]
                guard !token.isEmpty,
                      token.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
                    throw CheckedFFIIDError.invalidDecimalID
                }
            }
            searchStart = index
        }
    }

    private static func skipWhitespace(in value: String, index: inout String.Index) {
        while index < value.endIndex, value[index].isWhitespace {
            index = value.index(after: index)
        }
    }
}

struct SFTPSessionID: Hashable, Sendable, Codable, CustomStringConvertible {
    let decimalString: String

    init(_ rawValue: String) throws {
        decimalString = try canonicalDecimalID(rawValue)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(decimalString)
    }

    var ffiValue: UInt64 { UInt64(decimalString)! }
    var description: String { "sftp:\(decimalString)" }
}

struct TerminalChannelID: Hashable, Sendable, Codable, CustomStringConvertible {
    let decimalString: String

    init(_ rawValue: String) throws {
        decimalString = try canonicalDecimalID(rawValue)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(decimalString)
    }

    var ffiValue: UInt64 { UInt64(decimalString)! }
    var description: String { "terminal:\(decimalString)" }
}

struct HostKeyRequestID: Hashable, Sendable, Codable, CustomStringConvertible {
    static let maximumUTF8Length = 256

    let rawValue: String

    init() {
        rawValue = UUID().uuidString.lowercased()
    }

    init(_ rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= Self.maximumUTF8Length,
              rawValue.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 90)
                      || (byte >= 97 && byte <= 122)
                      || byte == 95
                      || byte == 46
                      || byte == 45
              }) else {
            throw CheckedFFIIDError.invalidRequestID
        }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { "request:\(rawValue)" }
}
