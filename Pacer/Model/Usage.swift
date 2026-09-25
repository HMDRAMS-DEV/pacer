import Foundation

enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude, codex

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// A rolling usage limit, such as the weekly cap.
struct UsageWindow: Equatable, Sendable {
    var usedPercent: Double
    var resetsAt: Date
    var length: TimeInterval

    var start: Date { resetsAt.addingTimeInterval(-length) }

    static let week: TimeInterval = 7 * 24 * 3600
}

/// Cumulative weekly usage at a moment in time.
struct UsagePoint: Equatable, Sendable {
    var date: Date
    var usedPercent: Double
}

struct ProviderUsage: Sendable {
    var weekly: UsageWindow
    var session: UsageWindow?
    /// Cumulative weekly usage within the current window, oldest first.
    var history: [UsagePoint]
    /// When the source last observed these numbers.
    var observedAt: Date
    /// True when the daily shape is estimated from token counts rather than measured.
    var historyIsEstimated: Bool
    var note: String?

    /// Weekly usage at `date`, from the last known point at or before it.
    func usedPercent(at date: Date) -> Double {
        guard date >= weekly.start else { return 0 }
        return history.last(where: { $0.date <= date })?.usedPercent ?? 0
    }

    /// Percent of the weekly limit spent between two moments.
    func spent(from start: Date, to end: Date) -> Double {
        guard end > start else { return 0 }
        return max(0, usedPercent(at: end) - usedPercent(at: start))
    }
}

enum SourceError: LocalizedError {
    case notFound(String)
    case signedOut
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let message), .unexpected(let message): message
        case .signedOut: "Your Claude Code sign-in has expired. Run `claude` in Terminal once to refresh it."
        }
    }
}

enum Dates {
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    /// Parses ISO 8601 timestamps with 0 to 9 fractional digits and a `Z` or numeric offset.
    static func parseISO(_ string: String) -> Date? {
        guard let dot = string.firstIndex(of: ".") else { return iso.date(from: string) }
        let digits = string[string.index(after: dot)...].prefix(while: \.isNumber)
        let fraction = Double("0." + digits) ?? 0
        var trimmed = string
        trimmed.removeSubrange(dot..<digits.endIndex)
        return iso.date(from: trimmed)?.addingTimeInterval(fraction)
    }
}
