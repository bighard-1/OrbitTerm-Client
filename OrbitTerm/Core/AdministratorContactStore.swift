import Foundation
import Combine

/// Public, origin-scoped data. No account credentials or recovery-policy claims are cached.
@MainActor
final class AdministratorContactStore: ObservableObject {
    private struct Record: Codable {
        let source: String
        let email: String
        let fetchedAt: TimeInterval
    }

    @Published private var displayedEmail = AdministratorContactPolicy.defaultEmail
    private let source: () -> String
    private let fetch: () async throws -> String?
    private let load: () -> Data?
    private let save: (Data?) -> Void
    private let wallNow: () -> TimeInterval
    private let uptime: () -> TimeInterval
    private var activeSource: String?
    private var expiresAtUptime: TimeInterval = 0
    private var lastAttempt: TimeInterval?
    private var requestID: UUID?
    private let lifetime: TimeInterval = 86_400

    var email: String {
        source() == activeSource && uptime() < expiresAtUptime
            ? displayedEmail : AdministratorContactPolicy.defaultEmail
    }

    init(source: @escaping () -> String, fetch: @escaping () async throws -> String?,
         load: @escaping () -> Data?, save: @escaping (Data?) -> Void,
         wallNow: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.source = source; self.fetch = fetch; self.load = load; self.save = save
        self.wallNow = wallNow; self.uptime = uptime
    }

    func refresh() async {
        let origin = source()
        let now = uptime()
        if origin != activeSource {
            activeSource = origin
            requestID = nil
            lastAttempt = nil
            displayedEmail = AdministratorContactPolicy.defaultEmail
            expiresAtUptime = 0
            if let data = load(), let record = try? JSONDecoder().decode(Record.self, from: data),
               record.source == origin, let email = AdministratorContactPolicy.validatedEmail(record.email) {
                let age = wallNow() - record.fetchedAt
                if age.isFinite && age >= 0 && age < lifetime {
                    displayedEmail = email
                    expiresAtUptime = now + lifetime - age
                }
            }
        }
        if now >= expiresAtUptime { displayedEmail = AdministratorContactPolicy.defaultEmail }
        guard requestID == nil else { return }
        if let lastAttempt, now >= lastAttempt && now - lastAttempt < 300 { return }
        lastAttempt = now
        let id = UUID()
        requestID = id
        defer { if requestID == id { requestID = nil } }
        do {
            let raw = try await fetch()
            try Task.checkCancellation()
            guard requestID == id, source() == origin else { return }
            // An omitted/empty field is the administrator explicitly using the default.
            let candidate: String
            if let raw, !raw.isEmpty {
                guard let validated = AdministratorContactPolicy.validatedEmail(raw) else { return }
                candidate = validated
            } else { candidate = AdministratorContactPolicy.defaultEmail }
            let record = Record(source: origin, email: candidate, fetchedAt: wallNow())
            save(try JSONEncoder().encode(record))
            expiresAtUptime = uptime() + lifetime
            displayedEmail = candidate
        } catch is CancellationError {
            if requestID == id { lastAttempt = nil }
        } catch {
            if Task.isCancelled {
                if requestID == id { lastAttempt = nil }
                return
            }
            // Offline/invalid policy must not overwrite a still-valid cached contact.
            if uptime() >= expiresAtUptime { displayedEmail = AdministratorContactPolicy.defaultEmail }
        }
    }
}
