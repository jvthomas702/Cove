import Foundation

/// The one countdown Cove runs at a time: a quick timer or a focus session.
/// Running timers store their end date, so they survive a restart.
struct QuickTimer: Codable, Equatable {
    var label: String
    /// The length it was started with, for the progress ring.
    var total: TimeInterval
    /// When it reaches zero; nil while paused.
    var endDate: Date?
    /// Time left when it was paused.
    var pausedRemaining: TimeInterval?

    static func start(seconds: TimeInterval, label: String, now: Date = Date()) -> QuickTimer {
        QuickTimer(label: label, total: seconds, endDate: now.addingTimeInterval(seconds), pausedRemaining: nil)
    }

    var isPaused: Bool { endDate == nil }

    func remaining(at now: Date = Date()) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return max(0, pausedRemaining ?? 0)
    }

    /// 1 when it starts, 0 at the end.
    func fractionLeft(at now: Date = Date()) -> Double {
        min(max(remaining(at: now) / max(total, 1), 0), 1)
    }

    func paused(at now: Date = Date()) -> QuickTimer {
        guard !isPaused else { return self }
        var copy = self
        copy.pausedRemaining = remaining(at: now)
        copy.endDate = nil
        return copy
    }

    func resumed(at now: Date = Date()) -> QuickTimer {
        guard isPaused else { return self }
        var copy = self
        copy.endDate = now.addingTimeInterval(pausedRemaining ?? 0)
        copy.pausedRemaining = nil
        return copy
    }

    /// "4:59", "12:00", "1:15:00". Rounds up, so a fresh 5-minute timer reads 5:00 and 0:00 means done.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds).rounded(.up))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "5 min", "90 sec", "1 hr 15 min": a timer's length in words.
    static func name(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) sec" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) sec" }
        let minutes = (s % 3600) / 60
        return minutes == 0 ? "\(s / 3600) hr" : "\(s / 3600) hr \(minutes) min"
    }

    // MARK: Parsing what you type

    /// The longest timer the field accepts.
    static let longest: TimeInterval = 24 * 3600

    /// Seconds from what you type in the timer field:
    /// "3" (minutes), "90s", "1h 15m", "1.5h", "25 min", "1:15:00" (h:mm:ss),
    /// or a clock time to count down to: "12:30", "9:05pm", "7pm". A clock time without am/pm
    /// means whichever 12:30 comes next. Nil when it can't be read, is zero, or is over 24 hours.
    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> TimeInterval? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        let seconds: TimeInterval?
        if let clock = untilClockTime(text, now: now, calendar: calendar) {
            seconds = clock
        } else if let match = groups(#"^(\d+):(\d{1,2}):(\d{2})$"#, in: text) {
            guard let m = Double(match[1]), let s = Double(match[2]), m < 60, s < 60 else { return nil }
            seconds = (Double(match[0]) ?? 0) * 3600 + m * 60 + s
        } else if let minutes = Double(text) {
            seconds = minutes * 60
        } else {
            seconds = unitDuration(text)
        }
        guard let seconds, seconds >= 1, seconds <= longest else { return nil }
        return seconds.rounded()
    }

    /// "1h 15m", "90s", "2 hours and 5 minutes".
    private static func unitDuration(_ text: String) -> TimeInterval? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*([a-z]+)"#) else { return nil }
        let ns = text as NSString
        var total: TimeInterval = 0
        var rest = text
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        for match in matches {
            guard let value = Double(ns.substring(with: match.range(at: 1))) else { return nil }
            let unit = ns.substring(with: match.range(at: 2))
            switch unit {
            case "h", "hr", "hrs", "hour", "hours": total += value * 3600
            case "m", "min", "mins", "minute", "minutes": total += value * 60
            case "s", "sec", "secs", "second", "seconds": total += value
            default: return nil
            }
            rest = rest.replacingOccurrences(of: ns.substring(with: match.range), with: " ")
        }
        // Nothing else but spaces, commas and "and".
        let leftover = rest.replacingOccurrences(of: "and", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
        return leftover.isEmpty ? total : nil
    }

    /// Seconds until the next "12:30", "9:05pm" or "7pm".
    private static func untilClockTime(_ text: String, now: Date, calendar: Calendar) -> TimeInterval? {
        let hour: Int, minute: Int, suffix: String
        if let match = groups(#"^(\d{1,2}):(\d{2})\s*(am|pm|a|p)?$"#, in: text) {
            guard let h = Int(match[0]), let m = Int(match[1]) else { return nil }
            hour = h; minute = m; suffix = match[2]
        } else if let match = groups(#"^(\d{1,2})\s*(am|pm|a|p)$"#, in: text) {
            guard let h = Int(match[0]) else { return nil }
            hour = h; minute = 0; suffix = match[1]
        } else {
            return nil
        }
        guard minute < 60, hour < 24 else { return nil }
        let hours: [Int]
        if !suffix.isEmpty {
            guard (1...12).contains(hour) else { return nil }
            hours = [hour % 12 + (suffix.hasPrefix("p") ? 12 : 0)]
        } else if hour == 0 || hour > 12 {
            hours = [hour]
        } else {
            hours = [hour % 12, hour % 12 + 12]   // 12:30 could be just after noon or midnight
        }
        let today = calendar.startOfDay(for: now)
        var next: Date?
        for day in 0...1 {
            guard let date = calendar.date(byAdding: .day, value: day, to: today) else { continue }
            for h in hours {
                guard let candidate = calendar.date(bySettingHour: h, minute: minute, second: 0, of: date),
                      candidate > now else { continue }
                if next.map({ candidate < $0 }) ?? true { next = candidate }
            }
        }
        return next.map { $0.timeIntervalSince(now) }
    }

    /// The capture groups of a whole-string match ("" for a group that didn't take part).
    private static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        else { return nil }
        return (1..<match.numberOfRanges).map { i in
            let range = match.range(at: i)
            return range.location == NSNotFound ? "" : (text as NSString).substring(with: range)
        }
    }
}

/// Keeps the running timer across restarts.
struct QuickTimerStore {
    let defaults: UserDefaults
    static let key = "quickTimer.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> QuickTimer? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(QuickTimer.self, from: data)
    }

    func save(_ timer: QuickTimer?) {
        if let timer, let data = try? JSONEncoder().encode(timer) {
            defaults.set(data, forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }
}
