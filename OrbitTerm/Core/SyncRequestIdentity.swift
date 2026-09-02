import CryptoKit
import Foundation

/// Opaque request identities remain stable when a server commits a mutation
/// but the client loses the response. They contain no account or plaintext
/// configuration data.
enum SyncRequestIdentity {
    static let header = "Idempotency-Key"

    static func upload(_ payload: UploadConfigRequest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(payload)) ?? Data()
        return digest(prefix: "config-upload-v1", payload: encoded)
    }

    static func mutation(_ request: AssetMutationRequest) -> String {
        digest(prefix: "asset-mutation-v1", payload: Data(request.operation_id.utf8))
    }

    private static func digest(prefix: String, payload: Data) -> String {
        var framed = Data("\(prefix.utf8.count):\(prefix)\(payload.count):".utf8)
        framed.append(payload)
        return SHA256.hash(data: framed).map { String(format: "%02x", $0) }.joined()
    }
}
