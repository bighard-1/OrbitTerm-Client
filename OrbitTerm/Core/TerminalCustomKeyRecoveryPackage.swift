import Foundation
import CryptoKit
import CommonCrypto

/// Portable, credential-free package. Binary v1 fixes KDF cost before any
/// untrusted bytes are processed; no attacker-controlled work factor.
enum TerminalCustomKeyRecoveryPackage {
    static let magic = Data("OTKEYBK1".utf8)
    static let iterations: UInt32 = 600_000
    static let maxBytes = TerminalCustomKeyContract.maxBytes + 52
    static let rescueMagic = Data("OTKEYRS1".utf8)
    static let maxRescuePlaintext = 4 * 1024 * 1024 + 85
    static let maxRescueBytes = maxRescuePlaintext + 52
    enum Failure: LocalizedError {
        case password, format, authentication
        var errorDescription: String? {
            switch self {
            case .password: return "导出口令需至少 12 个字符、最多 256 个 UTF-8 字节，不能包含控制字符。"
            case .format: return "恢复文件格式不受支持或大小超限，原有配置未更改。"
            case .authentication: return "口令错误或文件已损坏，原有配置未更改。"
            }
        }
    }
    static func validPassword(_ password: String) -> Bool {
        password.unicodeScalars.count >= 12 && password.utf8.count <= 256 &&
            !password.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) } &&
            password.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }
    static func seal(_ envelope: TerminalCustomKeyEnvelope, password: String) throws -> Data {
        let salt = try random(16), nonce = try random(12)
        return try seal(envelope, password: password, salt: salt, nonce: nonce)
    }
    // Deterministic entry point is internal for cross-language known-answer tests.
    static func seal(_ envelope: TerminalCustomKeyEnvelope, password: String, salt: Data, nonce: Data) throws -> Data {
        var plaintext = try TerminalCustomKeyContract.encode(envelope)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        return try sealBytes(plaintext, password: password, salt: salt, nonce: nonce, magic: magic)
    }
    private static func sealBytes(_ plaintext: Data, password: String, salt: Data, nonce: Data, magic: Data) throws -> Data {
        guard salt.count == 16, nonce.count == 12 else { throw Failure.format }
        let key = try derive(password, salt: salt)
        let header = magic + salt + nonce
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: header)
        return header + box.ciphertext + box.tag
    }
    static func open(_ package: Data, password: String) throws -> TerminalCustomKeyEnvelope {
        var plaintext = try openBytes(package, password: password, magic: magic, maximum: maxBytes)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        return try TerminalCustomKeyContract.decode(plaintext)
    }
    private static func openBytes(_ package: Data, password: String, magic: Data, maximum: Int) throws -> Data {
        guard (53...maximum).contains(package.count), package.prefix(8) == magic else { throw Failure.format }
        let key = try derive(password, salt: Data(package[8..<24]))
        var plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: package[24..<36]),
                ciphertext: package[36..<(package.count - 16)], tag: package.suffix(16))
            plaintext = try AES.GCM.open(box, using: key, authenticating: package.prefix(36))
        } catch { throw Failure.authentication }
        return plaintext
    }

    /// Read-only rescue is deliberately a different format from a valid-library backup.
    struct RescueSnapshot: Equatable {
        let platform: UInt8
        let account: String
        let sources: [UInt8: Data]

        func encoded() throws -> Data {
            guard account.utf8.count == 64, account.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !sources.isEmpty, sources.values.reduce(0, { $0 + $1.count }) <= 4 * 1024 * 1024,
                  (platform == 1 && Set(sources.keys) == [1]) ||
                    (platform == 2 && Set(sources.keys).isSubset(of: [2, 3, 4]) && (sources[2] != nil || sources[3] != nil)),
                  sources[4] == nil || sources[4] == Data([0]) || sources[4] == Data([1]),
                  (sources[2]?.count ?? 0) % 2 == 0, (sources[3]?.count ?? 0) % 2 == 0 else { throw Failure.format }
            var data = Data([platform]) + Data(account.utf8) + Data([UInt8(sources.count)])
            for tag in sources.keys.sorted() {
                let bytes = sources[tag]!
                data.append(tag)
                let length = UInt32(bytes.count)
                data.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) })
                data.append(bytes)
            }
            return data
        }
        static func decode(_ data: Data) throws -> Self {
            guard (71...maxRescuePlaintext).contains(data.count), let account = String(data: data[1..<65], encoding: .ascii),
                  (1...3).contains(data[65]) else { throw Failure.format }
            var offset = 66, sources: [UInt8: Data] = [:], previous: UInt8 = 0
            for _ in 0..<data[65] {
                guard offset + 5 <= data.count else { throw Failure.format }
                let tag = data[offset]
                let length = data[(offset + 1)..<(offset + 5)].reduce(0) { ($0 << 8) | Int($1) }
                offset += 5
                guard tag > previous, length <= data.count - offset else { throw Failure.format }
                sources[tag] = Data(data[offset..<(offset + length)])
                offset += length; previous = tag
            }
            guard offset == data.count else { throw Failure.format }
            let result = Self(platform: data[0], account: account, sources: sources)
            _ = try result.encoded()
            return result
        }
    }
    static func sealRescue(_ snapshot: RescueSnapshot, password: String) throws -> Data {
        var plaintext = try snapshot.encoded()
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        return try sealBytes(plaintext, password: password, salt: random(16), nonce: random(12), magic: rescueMagic)
    }
    static func openRescue(_ package: Data, password: String) throws -> RescueSnapshot {
        var plaintext = try openBytes(package, password: password, magic: rescueMagic, maximum: maxRescueBytes)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        return try RescueSnapshot.decode(plaintext)
    }
    private static func derive(_ password: String, salt: Data) throws -> SymmetricKey {
        guard validPassword(password) else { throw Failure.password }
        var bytes = Array(password.utf8), derived = [UInt8](repeating: 0, count: 32)
        defer {
            _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            _ = derived.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        let status = bytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress!.assumingMemoryBound(to: Int8.self), bytes.count,
                    saltBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw Failure.authentication }
        return SymmetricKey(data: derived)
    }
    private static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw Failure.authentication }
        return Data(bytes)
    }
}
