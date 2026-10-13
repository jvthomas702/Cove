import Foundation
import os
import SwiftUI

// MARK: - iCalendar parsing

/// One occurrence of a calendar item from an .ics feed.
struct ICSOccurrence: Equatable {
    var uid: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var url: URL?
}

/// A small, dependency-free iCalendar (RFC 5545) reader: enough for D2L/Brightspace, Canvas,
/// Google Calendar's "secret address", Outlook and iCloud feeds.
///
/// Handles folded lines, escaped text, UTC/TZID/floating/date-only times, DURATION, recurring
/// events (DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL, COUNT, UNTIL, BYDAY), EXDATE, moved or
/// cancelled single occurrences (RECURRENCE-ID), and cancelled events.
enum ICSParser {
    struct Property {
        let name: String
        let params: [String: String]
        let value: String
    }

    struct RawEvent {
        var props: [String: [Property]] = [:]
        func first(_ name: String) -> Property? { props[name]?.first }
        func all(_ name: String) -> [Property] { props[name] ?? [] }
    }

    /// Calendar name from X-WR-CALNAME, if the feed sets one.
    static func calendarName(_ text: String) -> String? {
        for line in unfold(text) where line.uppercased().hasPrefix("X-WR-CALNAME") {
            if let p = parseProperty(line), !p.value.isEmpty { return unescape(p.value) }
        }
        return nil
    }

    /// All occurrences overlapping [from, to].
    static func occurrences(in text: String, from: Date, to: Date) -> [ICSOccurrence] {
        let events = rawEvents(text)
        var masters: [RawEvent] = []
        var overrides: [String: [RawEvent]] = [:]   // uid → moved/cancelled instances
        for event in events {
            if event.first("STATUS")?.value.uppercased() == "CANCELLED" && event.first("RECURRENCE-ID") == nil { continue }
            if event.first("RECURRENCE-ID") != nil {
                overrides[event.first("UID")?.value ?? "", default: []].append(event)
            } else {
                masters.append(event)
            }
        }

        var result: [ICSOccurrence] = []
        for event in masters {
            guard let startProp = event.first("DTSTART"), let start = parseDate(startProp) else { continue }
            let uid = event.first("UID")?.value ?? UUID().uuidString
            let allDay = start.dateOnly
            let duration: TimeInterval = {
                if let endProp = event.first("DTEND"), let end = parseDate(endProp) { return max(0, end.date.timeIntervalSince(start.date)) }
                if let d = event.first("DURATION").flatMap({ parseDuration($0.value) }) { return d }
                return allDay ? 86_400 : 0
            }()

            let excluded: [Date] = event.all("EXDATE").flatMap { prop in
                prop.value.split(separator: ",").compactMap { part in
                    parseDate(Property(name: prop.name, params: prop.params, value: String(part)))?.date
                }
            }
            let moved = overrides[uid] ?? []
            let movedAway: [Date] = moved.compactMap { $0.first("RECURRENCE-ID").flatMap(parseDate)?.date }

            let starts: [Date]
            if let rule = event.first("RRULE")?.value {
                starts = expand(rule: rule, start: start, from: from.addingTimeInterval(-duration), until: to)
            } else {
                starts = [start.date]
            }

            for occurrenceStart in starts {
                let end = occurrenceStart.addingTimeInterval(duration)
                guard end >= from || (duration == 0 && occurrenceStart >= from), occurrenceStart <= to else { continue }
                if excluded.contains(where: { abs($0.timeIntervalSince(occurrenceStart)) < 60 }) { continue }
                if movedAway.contains(where: { abs($0.timeIntervalSince(occurrenceStart)) < 60 }) { continue }
                result.append(occurrence(event, uid: uid, start: occurrenceStart, end: end, allDay: allDay))
            }

            // Moved single instances (and skip ones that were cancelled).
            for override in moved {
                if override.first("STATUS")?.value.uppercased() == "CANCELLED" { continue }
                guard let s = override.first("DTSTART").flatMap(parseDate) else { continue }
                let e = override.first("DTEND").flatMap(parseDate)?.date ?? s.date.addingTimeInterval(duration)
                guard e >= from, s.date <= to else { continue }
                var o = occurrence(override, uid: uid, start: s.date, end: e, allDay: s.dateOnly)
                if o.title.isEmpty { o.title = unescape(event.first("SUMMARY")?.value ?? "") }
                result.append(o)
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    private static func occurrence(_ event: RawEvent, uid: String, start: Date, end: Date, allDay: Bool) -> ICSOccurrence {
        ICSOccurrence(
            uid: uid,
            title: unescape(event.first("SUMMARY")?.value ?? ""),
            start: start,
            end: end,
            isAllDay: allDay,
            location: event.first("LOCATION").map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 },
            notes: event.first("DESCRIPTION").map { unescape($0.value) },
            url: event.first("URL").flatMap { URL(string: $0.value) }
        )
    }

    // MARK: Lines and properties

    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, (first == " " || first == "\t"), !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }
        return lines
    }

    static func parseProperty(_ line: String) -> Property? {
        // Split at the first ':' that isn't inside a quoted parameter value.
        var inQuotes = false
        var splitIndex: String.Index?
        for index in line.indices {
            let c = line[index]
            if c == "\"" { inQuotes.toggle() }
            if c == ":" && !inQuotes { splitIndex = index; break }
        }
        guard let colon = splitIndex else { return nil }
        let head = line[..<colon]
        let value = String(line[line.index(after: colon)...])
        let parts = head.split(separator: ";")
        guard let name = parts.first else { return nil }
        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return Property(name: name.uppercased(), params: params, value: value)
    }

    static func rawEvents(_ text: String) -> [RawEvent] {
        var events: [RawEvent] = []
        var current: RawEvent?
        var depth = 0 // skip nested components like VALARM
        for line in unfold(text) {
            let upper = line.uppercased()
            if upper == "BEGIN:VEVENT" { current = RawEvent(); depth = 0; continue }
            if upper == "END:VEVENT" { if let c = current { events.append(c) }; current = nil; continue }
            guard current != nil else { continue }
            if upper.hasPrefix("BEGIN:") { depth += 1; continue }
            if upper.hasPrefix("END:") { depth -= 1; continue }
            guard depth == 0, let prop = parseProperty(line) else { continue }
            current?.props[prop.name, default: []].append(prop)
        }
        return events
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var escaping = false
        for c in s {
            if escaping {
                switch c {
                case "n", "N": out.append("\n")
                default: out.append(c)
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Dates

    struct ParsedDate {
        let date: Date
        let dateOnly: Bool
        let timeZone: TimeZone
    }

    /// Outlook/Exchange feeds use Windows zone names.
    private static let windowsZones: [String: String] = [
        "Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver", "Pacific Standard Time": "America/Los_Angeles",
        "US Mountain Standard Time": "America/Phoenix", "UTC": "UTC", "GMT Standard Time": "Europe/London",
    ]

    static func timeZone(_ tzid: String?) -> TimeZone {
        guard let tzid, !tzid.isEmpty else { return .current }
        if let tz = TimeZone(identifier: tzid) { return tz }
        if let mapped = windowsZones[tzid], let tz = TimeZone(identifier: mapped) { return tz }
        // Some feeds use "/mozilla.org/.../America/New_York"-style IDs.
        if let last = tzid.split(separator: "/").suffix(2).joined(separator: "/") as String?, let tz = TimeZone(identifier: last) { return tz }
        return .current
    }

    static func parseDate(_ prop: Property) -> ParsedDate? {
        let value = prop.value.trimmingCharacters(in: .whitespaces)
        let tz = timeZone(prop.params["TZID"])
        var calendar = Calendar(identifier: .gregorian)
        let digits = value.filter(\.isNumber)
        if prop.params["VALUE"]?.uppercased() == "DATE" || (value.count == 8 && digits.count == 8) {
            guard digits.count >= 8 else { return nil }
            calendar.timeZone = .current // all-day items belong to the viewer's day
            let y = Int(digits.prefix(4))!, m = Int(digits.dropFirst(4).prefix(2))!, d = Int(digits.dropFirst(6).prefix(2))!
            guard let date = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
            return ParsedDate(date: date, dateOnly: true, timeZone: .current)
        }
        guard digits.count >= 12 else { return nil }
        let utc = value.uppercased().hasSuffix("Z")
        calendar.timeZone = utc ? TimeZone(identifier: "UTC")! : tz
        let n = Array(digits)
        func num(_ a: Int, _ len: Int) -> Int { Int(String(n[a..<min(a + len, n.count)])) ?? 0 }
        let components = DateComponents(year: num(0, 4), month: num(4, 2), day: num(6, 2),
                                        hour: num(8, 2), minute: num(10, 2), second: n.count >= 14 ? num(12, 2) : 0)
        guard let date = calendar.date(from: components) else { return nil }
        return ParsedDate(date: date, dateOnly: false, timeZone: utc ? TimeZone(identifier: "UTC")! : tz)
    }

    /// "PT1H30M", "P1D", "-PT15M" → seconds.
    static func parseDuration(_ s: String) -> TimeInterval? {
        var value = s.uppercased()
        var sign: Double = 1
        if value.hasPrefix("-") { sign = -1; value.removeFirst() }
        if value.hasPrefix("+") { value.removeFirst() }
        guard value.hasPrefix("P") else { return nil }
        value.removeFirst()
        var total: Double = 0
        var number = ""
        var inTime = false
        for c in value {
            if c == "T" { inTime = true; continue }
            if c.isNumber { number.append(c); continue }
            let n = Double(number) ?? 0
            number = ""
            switch c {
            case "W": total += n * 7 * 86_400
            case "D": total += n * 86_400
            case "H": total += n * 3600
            case "M": total += inTime ? n * 60 : n * 30 * 86_400
            case "S": total += n
            default: break
            }
        }
        return sign * total
    }

    // MARK: Recurrence

    private static let weekdayCodes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    /// Occurrence start times for an RRULE between `from` and `until`. Rules with COUNT are walked from
    /// DTSTART (the count depends on it); others start near `from`, so years-old weekly classes stay cheap.
    static func expand(rule: String, start: ParsedDate, from windowStart: Date? = nil, until windowEnd: Date) -> [Date] {
        var parts: [String: String] = [:]
        for piece in rule.split(separator: ";") {
            let kv = piece.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { parts[kv[0].uppercased()] = String(kv[1]) }
        }
        let freq = parts["FREQ"]?.uppercased() ?? "DAILY"
        let interval = max(Int(parts["INTERVAL"] ?? "1") ?? 1, 1)
        let count = parts["COUNT"].flatMap { Int($0) }
        // A date-only UNTIL includes that whole day.
        let until = parts["UNTIL"].flatMap { parseDate(Property(name: "UNTIL", params: [:], value: $0)) }
            .map { $0.dateOnly ? $0.date.addingTimeInterval(86_399) : $0.date }
        let end = min(until ?? windowEnd, windowEnd)
        let byDay: Set<Int> = Set((parts["BYDAY"] ?? "").split(separator: ",").compactMap { code in
            weekdayCodes[String(code.suffix(2)).uppercased()]
        })

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = start.timeZone
        calendar.firstWeekday = 2 // ICS default WKST=MO
        let time = calendar.dateComponents([.hour, .minute, .second], from: start.date)
        let startDay = calendar.startOfDay(for: start.date)
        let startComponents = calendar.dateComponents([.year, .month, .day, .weekday], from: start.date)

        var results: [Date] = []
        var produced = 0
        var day = startDay
        if count == nil, let windowStart, let near = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: windowStart)), near > startDay {
            day = near
        }
        var guardDays = 0
        while day <= end && guardDays < 4000 {
            guardDays += 1
            let comps = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            let daysFromStart = calendar.dateComponents([.day], from: startDay, to: day).day ?? 0
            var matches = false
            switch freq {
            case "DAILY":
                matches = daysFromStart % interval == 0
            case "WEEKLY":
                let weekday = comps.weekday ?? 0
                let days = byDay.isEmpty ? [startComponents.weekday ?? 0] : Array(byDay)
                if days.contains(weekday) {
                    let startWeek = calendar.dateInterval(of: .weekOfYear, for: startDay)?.start ?? startDay
                    let thisWeek = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
                    let weeks = (calendar.dateComponents([.day], from: startWeek, to: thisWeek).day ?? 0) / 7
                    matches = weeks % interval == 0
                }
            case "MONTHLY":
                let months = (comps.year! - startComponents.year!) * 12 + (comps.month! - startComponents.month!)
                matches = comps.day == startComponents.day && months % interval == 0
            case "YEARLY":
                matches = comps.month == startComponents.month && comps.day == startComponents.day
                    && (comps.year! - startComponents.year!) % interval == 0
            default:
                matches = daysFromStart == 0
            }
            if matches, let occurrence = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day),
               occurrence >= start.date, occurrence <= end {
                results.append(occurrence)
                produced += 1
                if let count, produced >= count { break }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return results
    }
}

// MARK: - Feed monitor

struct FeedStatus: Identifiable, Equatable {
    var id: String { url }
    var url: String
    var name: String
    var state: State
    var itemCount = 0
    var fetchedAt: Date?

    enum State: Equatable { case loading, ok, failed(String) }
}

/// Fetches pasted calendar links (D2L, Canvas, Google's secret iCal address…) every 15 minutes.
/// No Calendar app setup or calendar permission needed.
final class ICSFeedMonitor {
    var onUpdate: (@MainActor (Schedule, [FeedStatus]) -> Void)?

    private let log = Logger(subsystem: "app.cove.island", category: "feeds")
    private var config: CoveConfig
    private var timer: Timer?
    private var ticks = 0
    private var cache: [String: [ICSOccurrence]] = [:]  // url → occurrences from the last good download
    private var statuses: [String: FeedStatus] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "Cove (macOS calendar reader)"]
        return URLSession(configuration: configuration)
    }()

    private static let palette: [UInt32] = [0x5AC8FA, 0xFF9F0A, 0xBF5AF2, 0x30D158, 0xFF375F, 0x64D2FF]

    init(config: CoveConfig) {
        self.config = config
    }

    /// Main thread.
    func start() {
        timer?.invalidate()
        // Re-sort every minute (so finished classes drop off); re-download every 15 minutes.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        fetchAll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        ticks += 1
        if ticks % 15 == 0 { fetchAll() } else { rebuild() }
    }

    func update(config: CoveConfig) {
        let changed = config.calendarFeeds != self.config.calendarFeeds
        self.config = config
        if changed {
            statuses = statuses.filter { config.calendarFeeds.contains($0.key) }
            cache = cache.filter { config.calendarFeeds.contains($0.key) }
            fetchAll()
        } else {
            rebuild()
        }
    }

    /// "webcal://…" → "https://…". Plain http is upgraded too (macOS blocks it), except on this Mac.
    static func normalize(_ link: String) -> URL? {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        for prefix in ["webcals://", "webcal://"] where lower.hasPrefix(prefix) {
            text = "https://" + text.dropFirst(prefix.count)
            break
        }
        // A saved .ics file works too.
        if text.lowercased().hasPrefix("file://") { return URL(string: text) }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = components.host, !host.isEmpty else { return nil }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1"
        if scheme == "http" && !local { components.scheme = "https" }
        return components.url
    }

    func fetchAll() {
        for link in config.calendarFeeds {
            guard let url = Self.normalize(link) else {
                statuses[link] = FeedStatus(url: link, name: "Calendar link", state: .failed("Not a calendar link"))
                continue
            }
            if statuses[link] == nil { statuses[link] = FeedStatus(url: link, name: url.host ?? link, state: .loading) }
            session.dataTask(with: url) { [weak self] data, response, error in
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let text = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }
                // Parse here, off the main thread: a Google feed can hold years of events.
                let now = Date()
                let parsed: (name: String?, items: [ICSOccurrence])? = text.flatMap { text in
                    guard text.contains("BEGIN:VCALENDAR") else { return nil }
                    return (ICSParser.calendarName(text),
                            ICSParser.occurrences(in: text, from: now.addingTimeInterval(-3 * 86_400), to: now.addingTimeInterval(45 * 86_400)))
                }
                DispatchQueue.main.async {
                    guard let self, self.config.calendarFeeds.contains(link) else { return }
                    if let parsed {
                        self.cache[link] = parsed.items
                        var status = self.statuses[link] ?? FeedStatus(url: link, name: url.host ?? link, state: .ok)
                        status.name = Self.displayName(parsed.name, url: url)
                        status.state = .ok
                        status.fetchedAt = Date()
                        self.statuses[link] = status
                    } else if error != nil, self.cache[link] != nil {
                        // Offline for a moment (just woke up, Wi-Fi switching): keep showing what we had.
                        self.log.info("Feed unreachable, keeping the last copy")
                    } else {
                        let reason = error?.localizedDescription
                            ?? (code == 401 || code == 403 ? "The link was refused. Copy a fresh one." : code == 404 ? "Link not found" : "That link didn't return a calendar")
                        self.log.error("Feed failed (\(code)): \(reason, privacy: .public)")
                        var status = self.statuses[link] ?? FeedStatus(url: link, name: Self.friendlyName(url), state: .failed(reason))
                        status.state = .failed(reason)
                        self.statuses[link] = status
                    }
                    self.rebuild()
                }
            }.resume()
        }
        rebuild()
    }

    /// D2L names its feed after the person ("Jason Thomas"), so the source name wins there.
    static func displayName(_ calendarName: String?, url: URL) -> String {
        let friendly = friendlyName(url)
        guard let calendarName, !calendarName.isEmpty else { return friendly }
        if ["D2L", "Canvas"].contains(friendly) && !calendarName.localizedCaseInsensitiveContains(friendly) {
            return friendly
        }
        return calendarName
    }

    static func friendlyName(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("d2l") || host.contains("brightspace") || url.path.lowercased().contains("d2l") { return "D2L" }
        if host.contains("instructure") || host.contains("canvas") { return "Canvas" }
        if host.contains("google") { return "Google Calendar" }
        if host.contains("outlook") || host.contains("office") { return "Outlook" }
        if host.contains("icloud") { return "iCloud" }
        return host.isEmpty ? "Calendar" : host
    }

    private func rebuild() {
        let now = Date()
        let horizon = now.addingTimeInterval(TimeInterval(max(config.dueLookaheadDays, 1)) * 86_400)
        var schedule = Schedule()
        var finalStatuses: [FeedStatus] = []
        for (index, link) in config.calendarFeeds.enumerated() {
            var status = statuses[link] ?? FeedStatus(url: link, name: "Calendar link", state: .loading)
            defer { finalStatuses.append(status) }
            guard let items = cache[link], let url = Self.normalize(link) else { continue }
            let color = Color(hex: Self.palette[index % Self.palette.count])
            // The URL's host helps spot LMS feeds even if the calendar's name doesn't.
            let classifierName = "\(status.name) \(Self.friendlyName(url))"
            var count = 0
            for item in items where item.end >= now.addingTimeInterval(-3 * 86_400) && item.start <= horizon {
                let title = item.title.isEmpty ? "Untitled" : item.title
                switch CalendarClassifier.classify(title: title, calendarTitle: classifierName, start: item.start, end: item.end,
                                                   isAllDay: item.isAllDay, extraLMS: config.assignmentCalendars) {
                case .due:
                    let due = item.isAllDay
                        ? (Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: item.start) ?? item.start)
                        : item.start
                    schedule.due.append(DueItem(id: "\(item.uid)@\(due.timeIntervalSince1970)", title: CalendarMonitor.cleanDueTitle(title),
                                                due: due, source: status.name, color: color))
                    count += 1
                case .event:
                    guard item.end > now, item.start < now.addingTimeInterval(48 * 3600) else { continue }
                    let text = [item.location, item.notes, item.url?.absoluteString].compactMap { $0 }.joined(separator: "\n")
                    schedule.events.append(CalEvent(
                        id: "\(item.uid)@\(item.start.timeIntervalSince1970)", title: title, start: item.start, end: item.end,
                        location: item.location?.components(separatedBy: "\n").first, calendar: status.name, color: color,
                        joinURL: CalendarMonitor.findJoinURL(in: text)
                    ))
                    count += 1
                case .skip:
                    continue
                }
            }
            status.itemCount = count
            statuses[link] = status
        }
        let callback = onUpdate
        let result = schedule
        let list = finalStatuses
        Task { @MainActor in callback?(result, list) }
    }
}

extension ICSFeedMonitor: @unchecked Sendable {}

extension Schedule {
    /// Combines Calendar-app and feed items, dropping duplicates (same title and start).
    static func merged(_ parts: [Schedule]) -> Schedule {
        var out = Schedule()
        var seenEvents = Set<String>()
        var seenDue = Set<String>()
        for part in parts {
            for e in part.events where seenEvents.insert("\(e.title.lowercased())|\(Int(e.start.timeIntervalSince1970 / 60))").inserted {
                out.events.append(e)
            }
            for d in part.due where seenDue.insert("\(d.title.lowercased())|\(Int(d.due.timeIntervalSince1970 / 60))").inserted {
                out.due.append(d)
            }
        }
        out.events.sort { $0.start < $1.start }
        out.due.sort { $0.due < $1.due }
        return out
    }
}
