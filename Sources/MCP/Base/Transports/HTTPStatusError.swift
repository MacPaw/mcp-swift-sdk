import Foundation

/// An HTTP status a server answered a request with that the transport does not handle itself: 429 or 5xx.
///
/// `localizedDescription` is the text `MCPError.internalError` gave for these statuses before, so a caller that shows
/// the error shows the same words.
public struct HTTPStatusError: Error, LocalizedError, Sendable, Hashable {
    public let statusCode: Int
    /// The response's `Retry-After`, in seconds from when the response came: its delta-seconds, or the time until its
    /// HTTP date (0 when that date has passed). `nil` when the header is missing or unreadable.
    public let retryAfter: TimeInterval?

    public init(statusCode: Int, retryAfter: TimeInterval? = nil) {
        self.statusCode = statusCode
        self.retryAfter = retryAfter
    }

    public var errorDescription: String? {
        MCPError.internalError(statusCode == 429 ? "Too many requests" : "Server error: \(statusCode)").errorDescription
    }

    /// Reads a `Retry-After` value (RFC 9110 §10.2.3) relative to `now`.
    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) {
            return seconds >= 0 ? TimeInterval(seconds) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let date = formatter.date(from: value) else { return nil }
        return max(date.timeIntervalSince(now), 0)
    }
}
