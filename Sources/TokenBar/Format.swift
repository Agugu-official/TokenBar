import Foundation
import TokenBarCore

/// Small display formatters shared by the tray title and the popover.
enum Format {
    /// Compact token count: 999 → "999", 12_345 → "12.3K", 1_234_567 → "1.2M".
    static func compactTokens(_ count: Int64) -> String {
        let value = Double(count)
        let scaled: Double
        let suffix: String
        switch value {
        case 1_000_000_000...:
            (scaled, suffix) = (value / 1_000_000_000, "B")
        case 1_000_000...:
            (scaled, suffix) = (value / 1_000_000, "M")
        case 1_000...:
            (scaled, suffix) = (value / 1_000, "K")
        default:
            return String(count)
        }
        var text = scaled >= 100 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text + suffix
    }

    static func usd(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }

    /// Today's contribution-graph day key. tokscale-core buckets days in the
    /// local timezone as `%Y-%m-%d`, so we must match that exactly.
    /// `timeZone` is injectable so a test can pin one. It defaults to
    /// `.current`, which is what every caller wants and what made the day-key
    /// assertions pass on the author's machine and fail on a UTC runner: an
    /// instant expressed as "07:33 local" is only that in one zone.
    static func todayKey(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    /// `todayKey` shifted back whole days, in the same `yyyy-MM-dd` shape the
    /// contributions are keyed and ordered by.
    ///
    /// Counted in calendar days through `Calendar`, not by subtracting
    /// `86_400 * n` seconds: a DST transition makes one of those days 23 or 25
    /// hours long, and the arithmetic version silently lands on the wrong date
    /// twice a year.
    static func dayKey(
        daysAgo: Int, now: Date = Date(), timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let shifted = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        return todayKey(now: shifted, timeZone: timeZone)
    }

    private static let monthsShort = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// "2026-06-10" → "Jun 10" ("6月10日" under zh-Hant).
    static func monthDay(_ iso: String) -> String {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return iso }
        return "format.monthDay".localized(
            default: "%1$@ %2$lld", monthsShort[parts[1] - 1].localized, parts[2])
    }

    /// "2026-07" → "Jul 2026" ("2026年7月" under zh-Hant).
    static func monthYear(_ ym: String) -> String {
        let parts = ym.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]) else { return ym }
        return "format.monthYear".localized(
            default: "%1$@ %2$lld", monthsShort[parts[1] - 1].localized, parts[0])
    }

    /// "2026-06-10" → "06/10".
    static func mmdd(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3 else { return iso }
        return "\(parts[1])/\(parts[2])"
    }

    /// Exact token count with thousands separators ("1,234,567").
    static func exactTokens(_ count: Int64) -> String {
        count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// Compact "time ago" from a Unix-seconds timestamp: "just now", "5m ago",
    /// "3h ago", "2d ago". Used for the pricing-data freshness hint.
    static func relativeTime(_ epochSecs: UInt64, now: Date = Date()) -> String {
        let diff = max(0, Int(now.timeIntervalSince1970) - Int(epochSecs))
        if diff < 60 { return "just now".localized }
        if diff < 3600 { return "%lldm ago".localized(diff / 60) }
        if diff < 86400 { return "%lldh ago".localized(diff / 3600) }
        return "%lldd ago".localized(diff / 86400)
    }
}

extension Format {
    /// Coarse remaining-time, e.g. "54m", "3h 54m", "5d 14h". Answers "how
    /// long have I got" and nothing finer; a window countdown that ticks
    /// seconds would redraw the card for no information.
    static func duration(ms: Int64) -> String {
        let mins = max(ms / 60_000, 0)
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h \(mins % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// Wall-clock span of a hovered interval. POSIX locale so the string is
    /// stable under test, but the user's own time zone and calendar.
    /// One instant, always the same width.
    ///
    /// `clockRange` drops the date when both ends share a day, which reads well
    /// in a tooltip about one interval and badly in a list of them: a five-hour
    /// window crosses midnight often enough that half the rows carried dates
    /// and half did not, and the two-date form ran to 23 characters and
    /// truncated. Every cycle of a window is the same length, so the end is
    /// derivable and the start alone identifies the row.
    static func windowStamp(ms: Int64) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "MM-dd HH:mm"
        return stamp.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func clockRange(fromMs: Int64, toMs: Int64) -> String {
        let from = Date(timeIntervalSince1970: Double(fromMs) / 1000)
        let to = Date(timeIntervalSince1970: Double(toMs) / 1000)
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        let sameDay = Calendar.current.isDate(from, inSameDayAs: to)
        if sameDay { return "\(time.string(from: from)) – \(time.string(from: to))" }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "MM-dd HH:mm"
        return "\(stamp.string(from: from)) – \(stamp.string(from: to))"
    }
}
