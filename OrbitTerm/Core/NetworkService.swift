import Foundation
import Security
import os

// NetworkService 负责与 OrbitTerm 后端进行 HTTP 通信。
// 采用 async/await 风格，便于与 SwiftUI 并发模型结合。
final class NetworkService: NSObject {
    static let shared = NetworkService()

    // 默认后端地址：首次启动直接指向正式域名。
    // 同时支持从 UserDefaults 读取已保存的自定义地址。
    private static let baseURLKey = "orbitterm.network.base_url"
    private static let defaultBaseURLString = "https://server.orbitterm.com"
    private static let defaultHost = "server.orbitterm.com"

    private let logger = Logger(subsystem: "com.orbitterm.app", category: "network")
    private let keychain = KeychainManager.shared
    private let tokenService = "com.orbitterm.auth"
    private let tokenAccount = "jwt_token"
    private let refreshTokenAccount = "jwt_refresh_token"
    private let refreshCoordinator = RefreshCoordinator()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    enum NetworkError: Error, LocalizedError {
        case invalidURL
        case invalidBaseURL
        case insecureScheme
        case server(String)
        case unexpectedStatus(Int)
        case unauthorized(String?)
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
            case let .unauthorized(message):
                if let message, !message.isEmpty {
                    return "未授权: \(message)"
                }
                return "未授权: Token 无效或已过期"
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

    var defaultBaseURLString: String {
        Self.defaultBaseURLString
    }

    // 写入自定义后端地址。入参允许省略 scheme，会自动补全为 https。
    // 只允许 https，避免明文 http 被 ATS 拦截或产生安全风险。
    func updateBaseURL(_ rawInput: String) throws {
        let normalized = try normalizeBaseURLString(rawInput)
        UserDefaults.standard.set(normalized, forKey: Self.baseURLKey)
    }

    // 在真正保存前提供预校验能力，便于 UI 做二次确认弹窗。
    func validatedBaseURLString(_ rawInput: String) throws -> String {
        try normalizeBaseURLString(rawInput)
    }

    func isDefaultEndpoint(_ rawInput: String) -> Bool {
        guard let host = URL(string: rawInput)?.host?.lowercased() else {
            return false
        }
        return host == Self.defaultHost
    }

    static func isRetriableNetworkError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .resourceUnavailable,
                 .internationalRoamingOff,
                 .callIsActive,
                 .dataNotAllowed:
                return true
            default:
                return false
            }
        }

        if let networkError = error as? NetworkError {
            switch networkError {
            case let .unexpectedStatus(code):
                return code == 408 || code == 429 || (500 ... 599).contains(code)
            default:
                return false
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            return isRetriableNetworkError(URLError(code))
        }

        return false
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

    func login(username: String, password: String) async throws -> LoginData {
        let body = AuthRequest(username: username, password: password)
        let data: LoginData = try await send(
            path: "/api/v1/auth/login",
            method: "POST",
            body: body,
            token: nil,
            responseType: LoginData.self
        )
        return data
    }

    func uploadConfig(token _: String, payload: UploadConfigRequest) async throws -> UploadConfigData {
        try await sendAuthorized(
            path: "/api/v1/config/upload",
            method: "POST",
            body: payload,
            responseType: UploadConfigData.self
        )
    }

    func pullConfigs(token _: String) async throws -> [UploadConfigData] {
        let data: PullConfigData = try await sendAuthorizedWithoutBody(
            path: "/api/v1/config/pull",
            method: "GET",
            responseType: PullConfigData.self
        )
        return data.items
    }

    func deleteConfig(id: UInt) async throws {
        try await sendAuthorizedRawWithoutBody(
            path: "/api/v1/config/\(id)",
            method: "DELETE"
        )
    }

    func pullConfigChanges(cursor: UInt64, limit: Int = 100) async throws -> SyncPullData {
        try await sendAuthorizedWithoutBody(
            path: "/api/v1/config/sync/pull?cursor=\(cursor)&limit=\(min(max(limit, 1), 500))",
            method: "GET",
            responseType: SyncPullData.self
        )
    }

    func acknowledgeConfigSync(_ request: SyncAcknowledgementRequest) async throws {
        _ = try await sendAuthorized(
            path: "/api/v1/config/sync/ack",
            method: "POST",
            body: request,
            responseType: SyncAcknowledgementData.self
        )
    }

    func moveAssetToTrash(assetID: UUID, request: AssetMutationRequest) async throws -> UploadConfigData {
        try await sendAuthorized(
            path: "/api/v1/config/assets/\(assetID.uuidString)/delete",
            method: "POST",
            body: request,
            responseType: UploadConfigData.self
        )
    }

    func restoreAsset(assetID: UUID, request: AssetMutationRequest) async throws -> UploadConfigData {
        try await sendAuthorized(
            path: "/api/v1/config/assets/\(assetID.uuidString)/restore",
            method: "POST",
            body: request,
            responseType: UploadConfigData.self
        )
    }

    func purgeAsset(assetID: UUID, request: AssetMutationRequest) async throws -> UploadConfigData {
        try await sendAuthorized(
            path: "/api/v1/config/assets/\(assetID.uuidString)/purge",
            method: "POST",
            body: request,
            responseType: UploadConfigData.self
        )
    }

    func pullTrash(limit: Int = 100, offset: Int = 0) async throws -> TrashConfigData {
        try await sendAuthorizedWithoutBody(
            path: "/api/v1/config/trash?limit=\(min(max(limit, 1), 500))&offset=\(max(offset, 0))",
            method: "GET",
            responseType: TrashConfigData.self
        )
    }

    func findIdentityMatches(fingerprint: String) async throws -> IdentityMatchData {
        try await sendAuthorizedWithoutBody(
            path: "/api/v1/config/identity-match?fingerprint=\(fingerprint)",
            method: "GET",
            responseType: IdentityMatchData.self
        )
    }

    private func sendAuthorized<Req: Encodable, Resp: Decodable>(
        path: String,
        method: String,
        body: Req,
        responseType: Resp.Type
    ) async throws -> Resp {
        let token = try readAccessToken()
        do {
            return try await send(
                path: path,
                method: method,
                body: body,
                token: token,
                responseType: responseType
            )
        } catch let error as NetworkError {
            guard case .unauthorized = error else { throw error }
            let refreshed = try await refreshAndPersistAccessToken()
            return try await send(
                path: path,
                method: method,
                body: body,
                token: refreshed,
                responseType: responseType
            )
        }
    }

    private func sendAuthorizedWithoutBody<Resp: Decodable>(
        path: String,
        method: String,
        responseType: Resp.Type
    ) async throws -> Resp {
        let token = try readAccessToken()
        do {
            return try await sendWithoutBody(
                path: path,
                method: method,
                token: token,
                responseType: responseType
            )
        } catch let error as NetworkError {
            guard case .unauthorized = error else { throw error }
            let refreshed = try await refreshAndPersistAccessToken()
            return try await sendWithoutBody(
                path: path,
                method: method,
                token: refreshed,
                responseType: responseType
            )
        }
    }
    private func sendAuthorizedRawWithoutBody(
        path: String,
        method: String
    ) async throws {
        let token = try readAccessToken()
        do {
            try await sendRawWithoutBody(path: path, method: method, token: token)
        } catch let error as NetworkError {
            guard case .unauthorized = error else { throw error }
            let refreshed = try await refreshAndPersistAccessToken()
            try await sendRawWithoutBody(path: path, method: method, token: refreshed)
        }
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
        request.timeoutInterval = 15
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, httpResp, latencyMs, attempts) = try await executeRequest(request)
        let requestURLString = request.url?.absoluteString ?? path

        let envelope = try? JSONDecoder().decode(APIEnvelope<Resp>.self, from: data)
        await MainActor.run {
            DiagnosticsManager.shared.record(
                method: method,
                url: requestURLString,
                statusCode: httpResp.statusCode,
                latencyMs: latencyMs,
                errorType: nil,
                attempt: attempts
            )
        }
        if !(200 ... 299).contains(httpResp.statusCode) {
            if httpResp.statusCode == 401 {
                throw NetworkError.unauthorized(envelope?.error)
            }
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

    private func sendRawWithoutBody(path: String, method: String, token: String?) async throws {
        let baseURL = try resolvedBaseURL()
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, httpResp, latencyMs, attempts) = try await executeRequest(request)
        let requestURLString = request.url?.absoluteString ?? path
        let envelope = try? JSONDecoder().decode(APIEnvelope<EmptyResponseData>.self, from: data)
        await MainActor.run {
            DiagnosticsManager.shared.record(
                method: method,
                url: requestURLString,
                statusCode: httpResp.statusCode,
                latencyMs: latencyMs,
                errorType: nil,
                attempt: attempts
            )
        }
        guard (200 ... 299).contains(httpResp.statusCode) else {
            if httpResp.statusCode == 401 {
                throw NetworkError.unauthorized(envelope?.error)
            }
            if let message = envelope?.error {
                throw NetworkError.server(message)
            }
            throw NetworkError.unexpectedStatus(httpResp.statusCode)
        }
    }

    private func sendWithoutBody<Resp: Decodable>(
        path: String,
        method: String,
        token: String?,
        responseType: Resp.Type
    ) async throws -> Resp {
        let baseURL = try resolvedBaseURL()
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, httpResp, latencyMs, attempts) = try await executeRequest(request)
        let requestURLString = request.url?.absoluteString ?? path

        let envelope = try? JSONDecoder().decode(APIEnvelope<Resp>.self, from: data)
        await MainActor.run {
            DiagnosticsManager.shared.record(
                method: method,
                url: requestURLString,
                statusCode: httpResp.statusCode,
                latencyMs: latencyMs,
                errorType: nil,
                attempt: attempts
            )
        }
        if !(200 ... 299).contains(httpResp.statusCode) {
            if httpResp.statusCode == 401 {
                throw NetworkError.unauthorized(envelope?.error)
            }
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

    private func executeRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse, Int, Int) {
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1 ... maxAttempts {
            let start = Date()
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResp = response as? HTTPURLResponse else {
                    throw NetworkError.unexpectedStatus(-1)
                }
                let latency = Int(Date().timeIntervalSince(start) * 1000)

                if (500 ... 599).contains(httpResp.statusCode), attempt < maxAttempts {
                    await MainActor.run { DiagnosticsManager.shared.beginRetry() }
                    defer { Task { @MainActor in DiagnosticsManager.shared.endRetry() } }
                    await MainActor.run {
                        DiagnosticsManager.shared.record(
                            method: request.httpMethod ?? "GET",
                            url: request.url?.absoluteString ?? "-",
                            statusCode: httpResp.statusCode,
                            latencyMs: latency,
                            errorType: "server_5xx_retry",
                            attempt: attempt
                        )
                    }
                    try? await Task.sleep(nanoseconds: retryBackoffNanos(for: attempt))
                    continue
                }
                return (data, httpResp, latency, attempt)
            } catch {
                lastError = error
                let latency = Int(Date().timeIntervalSince(start) * 1000)
                let isTimeout = isTimeoutError(error)
                await MainActor.run {
                    DiagnosticsManager.shared.record(
                        method: request.httpMethod ?? "GET",
                        url: request.url?.absoluteString ?? "-",
                        statusCode: nil,
                        latencyMs: latency,
                        errorType: "\(type(of: error))",
                        attempt: attempt
                    )
                }
                guard isTimeout, attempt < maxAttempts else { throw error }
                await MainActor.run { DiagnosticsManager.shared.beginRetry() }
                defer { Task { @MainActor in DiagnosticsManager.shared.endRetry() } }
                logger.debug("[NET] timeout retry attempt=\(attempt) url=\(request.url?.absoluteString ?? "-", privacy: .public)")
                try? await Task.sleep(nanoseconds: retryBackoffNanos(for: attempt))
            }
        }
        throw lastError ?? NetworkError.unexpectedStatus(-1)
    }

    private func retryBackoffNanos(for attempt: Int) -> UInt64 {
        switch attempt {
        case 1: return 2_000_000_000
        case 2: return 4_000_000_000
        default: return 8_000_000_000
        }
    }

    private func isTimeoutError(_ error: Error) -> Bool {
        if let url = error as? URLError {
            return url.code == .timedOut
        }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut
    }

    private func readAccessToken() throws -> String {
        let token = try keychain.readString(service: tokenService, account: tokenAccount)
        guard let token, !token.isEmpty else {
            throw NetworkError.unauthorized("access token 缺失")
        }
        return token
    }

    private func readRefreshToken() throws -> String {
        let token = try keychain.readString(service: tokenService, account: refreshTokenAccount)
        guard let token, !token.isEmpty else {
            throw NetworkError.unauthorized("refresh token 缺失")
        }
        return token
    }

    private func refreshAndPersistAccessToken() async throws -> String {
        try await refreshCoordinator.value {
            let refreshToken = try self.readRefreshToken()
            let payload = RefreshRequest(refresh_token: refreshToken)
            let refreshed: LoginData = try await self.send(
                path: "/api/v1/auth/refresh",
                method: "POST",
                body: payload,
                token: nil,
                responseType: LoginData.self
            )
            let access = refreshed.accessTokenValue
            guard !access.isEmpty else {
                throw NetworkError.unauthorized("refresh 响应缺少 access_token")
            }
            try self.keychain.saveString(access, service: self.tokenService, account: self.tokenAccount)
            if let newRefresh = refreshed.refreshTokenValue, !newRefresh.isEmpty {
                try self.keychain.saveString(newRefresh, service: self.tokenService, account: self.refreshTokenAccount)
            }
            self.logger.debug("[NET] token refreshed")
            return access
        }
    }
}

extension NetworkService: URLSessionDelegate {
    // 对默认正式域名执行额外 TLS 校验加固：
    // 1) 强制 hostname policy
    // 2) 强制系统信任评估通过
    // 3) 拒绝单证书（常见自签名）链路
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host.lowercased()
        guard host == Self.defaultHost else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let policy = SecPolicyCreateSSL(true, host as CFString)
        SecTrustSetPolicies(trust, policy)

        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // 基础防护：对默认域名拒绝单证书链（降低自签名风险）。
        let certCount = SecTrustGetCertificateCount(trust)
        guard certCount > 1 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
