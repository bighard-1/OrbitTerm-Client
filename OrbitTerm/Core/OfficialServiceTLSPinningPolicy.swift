import CryptoKit
import Foundation
import Security

/// The official API is authenticated twice: first by the platform's ordinary
/// hostname and certificate-chain validation, then by a SHA-256 hash of the
/// certificate's SubjectPublicKeyInfo (SPKI). Pins belong only to the official
/// host; explicitly approved self-hosted endpoints keep normal HTTPS trust.
///
/// Rotation protocol: ship the next public key in `acceptedSPKIHashes` before
/// deploying its matching certificate. Keep the old pin through one release
/// cycle, then remove it only after every supported client can accept the new
/// key. Never replace the final active pin in place.
enum OfficialServiceTLSPinningPolicy {
    static let officialHost = "server.orbitterm.com"

    /// Current public key for server.orbitterm.com, captured on 2026-08-02.
    /// This is an SPKI SHA-256 pin (not a leaf-certificate hash), so ordinary
    /// certificate renewal remains valid as long as the server key is kept.
    /// Add a pre-provisioned next key here before rotating the server key.
    static let acceptedSPKIHashes: Set<String> = [
        "ULrPyDI6UlPISD+MbZWAxttOqmh8YL6JE+DI+583Mco="
    ]

    static func requiresPinning(for host: String) -> Bool {
        host.lowercased() == officialHost
    }

    static func acceptsValidatedChainSPKIHashes(_ hashes: Set<String>) -> Bool {
        !hashes.isDisjoint(with: acceptedSPKIHashes)
    }

    static func spkiSHA256(for certificate: SecCertificate) throws -> String {
        let certificateData = SecCertificateCopyData(certificate) as Data
        let spki = try SubjectPublicKeyInfoExtractor.extract(fromCertificateDER: certificateData)
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }
}

/// Narrow DER reader for X.509's stable Certificate/TBSCertificate layout.
/// It returns the exact DER SubjectPublicKeyInfo object rather than a platform-
/// specific key serialization, which makes its SHA-256 value interoperable
/// with OpenSSL and standard SPKI pin tooling.
enum SubjectPublicKeyInfoExtractor {
    enum ExtractionError: Error, Equatable {
        case malformedDER
        case unexpectedCertificateLayout
    }

    static func extract(fromCertificateDER data: Data) throws -> Data {
        var cursor = DERCursor(data: data)
        let certificate = try cursor.readTLV()
        guard certificate.tag == 0x30, cursor.isAtEnd else {
            throw ExtractionError.unexpectedCertificateLayout
        }

        var certificateCursor = DERCursor(data: certificate.contents)
        let tbsCertificate = try certificateCursor.readTLV()
        guard tbsCertificate.tag == 0x30 else {
            throw ExtractionError.unexpectedCertificateLayout
        }

        var tbsCursor = DERCursor(data: tbsCertificate.contents)
        if tbsCursor.peekTag == 0xA0 { // Optional explicit version field.
            _ = try tbsCursor.readTLV()
        }
        // serialNumber, signature, issuer, validity, subject
        for _ in 0 ..< 5 {
            _ = try tbsCursor.readTLV()
        }
        let subjectPublicKeyInfo = try tbsCursor.readTLV()
        guard subjectPublicKeyInfo.tag == 0x30 else {
            throw ExtractionError.unexpectedCertificateLayout
        }
        return subjectPublicKeyInfo.fullDER
    }
}

private struct DERCursor {
    struct TLV {
        let tag: UInt8
        let contents: Data
        let fullDER: Data
    }

    private let data: Data
    private var index: Data.Index

    init(data: Data) {
        self.data = data
        index = data.startIndex
    }

    var isAtEnd: Bool { index == data.endIndex }

    var peekTag: UInt8? {
        guard index < data.endIndex else { return nil }
        return data[index]
    }

    mutating func readTLV() throws -> TLV {
        let start = index
        guard index < data.endIndex else {
            throw SubjectPublicKeyInfoExtractor.ExtractionError.malformedDER
        }
        let tag = data[index]
        index = data.index(after: index)
        let length = try readLength()
        guard length >= 0, data.distance(from: index, to: data.endIndex) >= length else {
            throw SubjectPublicKeyInfoExtractor.ExtractionError.malformedDER
        }
        let contentEnd = data.index(index, offsetBy: length)
        let contents = Data(data[index ..< contentEnd])
        let fullDER = Data(data[start ..< contentEnd])
        index = contentEnd
        return TLV(tag: tag, contents: contents, fullDER: fullDER)
    }

    private mutating func readLength() throws -> Int {
        guard index < data.endIndex else {
            throw SubjectPublicKeyInfoExtractor.ExtractionError.malformedDER
        }
        let first = data[index]
        index = data.index(after: index)
        if first & 0x80 == 0 {
            return Int(first)
        }
        let byteCount = Int(first & 0x7F)
        guard byteCount > 0, byteCount <= MemoryLayout<Int>.size,
              data.distance(from: index, to: data.endIndex) >= byteCount else {
            throw SubjectPublicKeyInfoExtractor.ExtractionError.malformedDER
        }
        var length = 0
        for _ in 0 ..< byteCount {
            length = (length << 8) | Int(data[index])
            index = data.index(after: index)
        }
        return length
    }
}
