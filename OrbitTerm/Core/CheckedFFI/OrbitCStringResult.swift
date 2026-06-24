import Foundation

struct OrbitCStringResultReader: @unchecked Sendable {
    typealias Releaser = @Sendable (UnsafeMutablePointer<CChar>) -> Void

    private let releaser: Releaser

    init(releaser: @escaping Releaser) {
        self.releaser = releaser
    }

    func take(_ pointer: UnsafeMutablePointer<CChar>?) throws -> String {
        guard let pointer else {
            throw CheckedFFIClientError.nullCStringResult
        }
        defer { releaser(pointer) }

        let byteCount = Int(strlen(pointer))
        let bytes = Data(bytes: pointer, count: byteCount)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw CheckedFFIClientError.invalidUTF8Result
        }
        return value
    }
}
