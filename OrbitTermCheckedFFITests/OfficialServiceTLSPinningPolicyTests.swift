import XCTest

final class OfficialServiceTLSPinningPolicyTests: XCTestCase {
    func testOfficialHostRequiresPinningButSelfHostedEndpointDoesNot() {
        XCTAssertTrue(OfficialServiceTLSPinningPolicy.requiresPinning(for: "server.orbitterm.com"))
        XCTAssertTrue(OfficialServiceTLSPinningPolicy.requiresPinning(for: "SERVER.ORBITTERM.COM"))
        XCTAssertFalse(OfficialServiceTLSPinningPolicy.requiresPinning(for: "sync.example.net"))
    }

    func testOnlyConfiguredSPKIPinsAreAccepted() {
        let activePin = try! XCTUnwrap(OfficialServiceTLSPinningPolicy.acceptedSPKIHashes.first)
        XCTAssertTrue(OfficialServiceTLSPinningPolicy.acceptsValidatedChainSPKIHashes([activePin]))
        XCTAssertFalse(OfficialServiceTLSPinningPolicy.acceptsValidatedChainSPKIHashes(["unrelated-pin"]))
        XCTAssertFalse(OfficialServiceTLSPinningPolicy.acceptsValidatedChainSPKIHashes([]))
    }

    func testExtractsExactSubjectPublicKeyInfoFromMinimalCertificateDER() throws {
        // Certificate ::= SEQUENCE { TBSCertificate, signatureAlgorithm,
        // signatureValue }. The fixture only supplies the fields the parser
        // needs to locate TBSCertificate.subjectPublicKeyInfo.
        let subjectPublicKeyInfo = Data([0x30, 0x03, 0x03, 0x01, 0x00])
        let tbsContents = Data([
            0x02, 0x01, 0x01, // serialNumber
            0x30, 0x00,       // signature
            0x30, 0x00,       // issuer
            0x30, 0x00,       // validity
            0x30, 0x00        // subject
        ]) + subjectPublicKeyInfo
        let tbs = Data([0x30, UInt8(tbsContents.count)]) + tbsContents
        let certificateContents = tbs + Data([0x30, 0x00, 0x03, 0x01, 0x00])
        let certificate = Data([0x30, UInt8(certificateContents.count)]) + certificateContents

        XCTAssertEqual(
            try SubjectPublicKeyInfoExtractor.extract(fromCertificateDER: certificate),
            subjectPublicKeyInfo
        )
    }

    func testMalformedCertificateDERFailsClosed() {
        XCTAssertThrowsError(
            try SubjectPublicKeyInfoExtractor.extract(fromCertificateDER: Data([0x30, 0x05, 0x30]))
        )
    }
}
