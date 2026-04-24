import Foundation

// NetworkService 负责与 OrbitTerm 后端进行 HTTP 通信。
// 采用 async/await 风格，便于与 SwiftUI 并发模型结合。
final class NetworkService {
    static let shared = NetworkService()

    // 默认后端地址：首次启动直接指向正式域名。
    // 同时支持从 UserDefaults 读取已保存的自定义地址。
    private static let baseURLKey = "orbitterm.network.base_url"
    private static let defaultBaseURLString = "https://server.orbitterm.com"

    private let session = URLSession.shared

    private init() {}

    enum NetworkError: Error, LocalizedError {
        case invalidURL
        case invalidBaseURL
        case insecureScheme
        case server(String)
        case unexpectedStatus(Int)
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "请求地址无效"
            case .invalidBaseURL:
                return "服务地址格式无效"
            case .insecureScheme:
                return "仅允许 HTTPS 服务地址"
            case let .server(message):
                return "服务端错误: \(message)"
            case let .unexpectedStatus(code):
                return "HTTP 状态异常: \(code)"
            case .decodeFailed:
                return "响应解析失败"
            }
        }
    }

    // 返回当前生效的后端地址字符串（用于调试或隐形设置）。
    // 若本地存储为空，自动返回内置默认值。
    var currentBaseURLString: String {
        UserDefaults.standard.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURLString
    }

    // 写入自定义后端地址。入参允许省略 scheme，会自动补全为 https。
    // 只允许 https，避免明文 http 被 ATS 拦截或产生安全风险。
    func updateBaseURL(_ rawInput: String) throws {
        let normalized = try normalizeBaseURLString(rawInput)
        UserDefaults.standard.set(normalized, forKey: Self.baseURLKey)
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
        let baseURL = try resolvedBaseURL()
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

    private func resolvedBaseURL() throws -> URL {
        let storedOrDefault = currentBaseURLString
        let normalized = try normalizeBaseURLString(storedOrDefault)
        guard let url = URL(string: normalized) else {
            throw NetworkError.invalidBaseURL
        }
        return url
    }

    private func normalizeBaseURLString(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NetworkError.invalidBaseURL
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var comps = URLComponents(string: candidate),
              let host = comps.host,
              !host.isEmpty else {
            throw NetworkError.invalidBaseURL
        }

        let scheme = (comps.scheme ?? "https").lowercased()
        guard scheme == "https" else {
            throw NetworkError.insecureScheme
        }

        comps.scheme = "https"
        comps.path = comps.path.isEmpty ? "" : comps.path

        guard let normalizedURL = comps.url else {
            throw NetworkError.invalidBaseURL
        }
        return normalizedURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
