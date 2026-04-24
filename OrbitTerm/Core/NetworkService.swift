import Foundation

// NetworkService 负责与 OrbitTerm 后端进行 HTTP 通信。
// 采用 async/await 风格，便于与 SwiftUI 并发模型结合。
final class NetworkService {
    static let shared = NetworkService()

    // iOS 模拟器与 macOS 本机都可通过 127.0.0.1 访问本地后端。
    // 若使用真机，请替换为宿主机局域网 IP。
    private let baseURL = URL(string: "http://127.0.0.1:8080")!
    private let session = URLSession.shared

    private init() {}

    enum NetworkError: Error, LocalizedError {
        case invalidURL
        case server(String)
        case unexpectedStatus(Int)
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "请求地址无效"
            case let .server(message):
                return "服务端错误: \(message)"
            case let .unexpectedStatus(code):
                return "HTTP 状态异常: \(code)"
            case .decodeFailed:
                return "响应解析失败"
            }
        }
    }

    func register(username: String, password: String) async throws {
        let body = AuthRequest(username: username, password: password)
        _ = try await send(
            path: "/api/v1/auth/register",
            method: "POST",
            body: body,
            token: nil,
            responseType: RegisterData.self
        )
    }

    func login(username: String, password: String) async throws -> String {
        let body = AuthRequest(username: username, password: password)
        let data: LoginData = try await send(
            path: "/api/v1/auth/login",
            method: "POST",
            body: body,
            token: nil,
            responseType: LoginData.self
        )
        return data.token
    }

    func uploadConfig(token: String, payload: UploadConfigRequest) async throws -> UploadConfigData {
        try await send(
            path: "/api/v1/config/upload",
            method: "POST",
            body: payload,
            token: token,
            responseType: UploadConfigData.self
        )
    }

    private func send<Req: Encodable, Resp: Decodable>(
        path: String,
        method: String,
        body: Req,
        token: String?,
        responseType: Resp.Type
    ) async throws -> Resp {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw NetworkError.unexpectedStatus(-1)
        }

        let envelope = try? JSONDecoder().decode(APIEnvelope<Resp>.self, from: data)
        if !(200 ... 299).contains(httpResp.statusCode) {
            if let message = envelope?.error {
                throw NetworkError.server(message)
            }
            throw NetworkError.unexpectedStatus(httpResp.statusCode)
        }

        guard let parsed = envelope,
              parsed.success,
              let payload = parsed.data else {
            throw NetworkError.decodeFailed
        }
        return payload
    }
}

struct AuthRequest: Encodable {
    let username: String
    let password: String
}

struct UploadConfigRequest: Encodable {
    let id: UInt?
    let encrypted_blob_base64: String
    let vector_clock: String
}

struct APIEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: String?
}

struct RegisterData: Decodable {
    let id: UInt
    let username: String
    let created_at: String
}

struct LoginData: Decodable {
    let token: String
    let type: String
}

struct UploadConfigData: Decodable {
    let id: UInt
    let user_id: UInt
    let encrypted_blob_base64: String
    let vector_clock: String
    let updated_at: String
}
