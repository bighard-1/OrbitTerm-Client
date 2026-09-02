import Foundation

enum SyncHTTPResponseDisposition: Equatable, Sendable {
    case authenticationExpired
    case retryable
    case permanentRejection
    case protocolViolation
}

/// Stable HTTP-to-sync contract shared with Android. Response bodies are never inspected.
enum SyncHTTPResponsePolicy {
    static let maximumRetryAfter: TimeInterval = 3_600

    static func disposition(statusCode: Int) -> SyncHTTPResponseDisposition {
        switch statusCode {
        case 401:
            return .authenticationExpired
        case 408, 425, 429, 500 ... 599:
            return .retryable
        case 400 ... 499:
            return .permanentRejection
        default:
            return .protocolViolation
        }
    }

    static func retryAfterSeconds(
        _ rawValue: String?,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let delay: TimeInterval?
        if let seconds = TimeInterval(value) {
            delay = seconds
        } else {
            delay = httpDate(value).map { ceil($0.timeIntervalSince(now)) }
        }
        guard let delay, delay > 0 else { return nil }
        return min(delay, maximumRetryAfter)
    }

    private static func httpDate(_ value: String) -> Date? {
        // RFC 9110 HTTP-date accepts IMF-fixdate plus two obsolete forms.
        let formats = [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
