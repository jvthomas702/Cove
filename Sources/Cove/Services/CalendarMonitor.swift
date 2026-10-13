import AppKit
import EventKit
import os
import SwiftUI

/// What Cove can see in Calendar (shown in Settings so it's obvious when something's missing).
struct CalendarStatus: Equatable {
    enum Access: Equatable { case notDetermined, granted, denied }
    var access: Access = .notDetermined
    var remindersAccess: Access = .notDetermined
    var calendars: [String] = []
    var classCount = 0
    var dueCount = 0
}

/// Decides whether a calendar item is a class/meeting or a due date. Pure, so it's unit-tested.
///
/// LMS feeds (D2L/Brightspace, Canvas…) mix both: class sessions are timed events with a length,
/// assignments are zero-length (or all-day) items at the due moment, often titled "… - Due".
enum CalendarClassifier {
    enum Kind: Equatable { case event, due, skip }

    static let lmsHints = ["d2l", "brightspace", "canvas", "gradescope", "blackboard", "moodle", "assignment", "coursework"]

    static func isLMSCalendar(_ title: String, extra: [String]) -> Bool {
        if extra.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) { return true }
        let lower = title.lowercased()
        return lmsHints.contains { lower.contains($0) }
    }

    static func looksDue(_ title: String) -> Bool {
        let lower = title.lowercased()
        return ["due", "deadline", "submission", "submit", "closes", "assignment", "quiz available", "availability ends"]
            .contains { lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
    }

    static func classify(title: String, calendarTitle: String, start: Date, end: Date, isAllDay: Bool, extraLMS: [String]) -> Kind {
        let minutes = end.timeIntervalSince(start) / 60
        let lms = isLMSCalendar(calendarTitle, extra: extraLMS)
        if isAllDay {
            // All-day items in an LMS feed are due dates; elsewhere (holidays, birthdays) they're skipped.
            return lms || looksDue(title) ? .due : .skip
        }
        if minutes <= 1 { return lms || looksDue(title) ? .due : .event }
        if lms && looksDue(title) { return .due }
        return .event
    }
}

/// Reads your Mac's Calendar (classes, meetings) and Reminders (due dates) via EventKit.
/// Google, iCloud, Exchange and subscribed calendars all work once they're in the Calendar app.
final class CalendarMonitor {
    var onUpdate: (@MainActor (Schedule) -> Void)?
    var onStatus: (@MainActor (CalendarStatus) -> Void)?
    var onAccessDenied: (@MainActor () -> Void)?

    private let log = Logger(subsystem: "app.cove.island", category: "calendar")
    private var store = EKEventStore()
    private var config: CoveConfig
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var lastAccess: (Bool, Bool) = (false, false)
    private var reportedDenied = false

    private static let joinHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com"]

    init(config: CoveConfig) {
        self.config = config
    }

    func update(config: CoveConfig) {
        self.config = config
        refresh()
    }

    /// Asks for access if it was never asked, then keeps refreshing (and notices access granted later).
    func start() {
        Task { [weak self] in
            guard let self else { return }
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                _ = try? await self.store.requestFullAccessToEvents()
            }
            if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
                _ = try? await self.store.requestFullAccessToReminders()
            }
            await MainActor.run { self.begin() }
        }
    }

    @MainActor
    private func begin() {
        observe()
        // Every minute: cheap, and picks up access granted in System Settings without a restart.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func observe() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private static func allowed(_ type: EKEntityType) -> Bool {
        EKEventStore.authorizationStatus(for: type) == .fullAccess
    }

    private static func access(_ type: EKEntityType) -> CalendarStatus.Access {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func refresh() {
        let eventsAllowed = Self.allowed(.event)
        let remindersAllowed = Self.allowed(.reminder)
        // A store created before access was granted can stay empty, so start fresh when access changes.
        if (eventsAllowed, remindersAllowed) != lastAccess {
            if eventsAllowed || remindersAllowed {
                store = EKEventStore()
                observe()
                log.info("Calendar access changed: events \(eventsAllowed), reminders \(remindersAllowed)")
            }
            lastAccess = (eventsAllowed, remindersAllowed)
        }
        if !eventsAllowed && !remindersAllowed && Self.access(.event) == .denied && !reportedDenied {
            reportedDenied = true
            let denied = onAccessDenied
            Task { @MainActor in denied?() }
        }

        let config = self.config
        var schedule = Schedule()
        var status = CalendarStatus(access: Self.access(.event), remindersAccess: Self.access(.reminder))
        let now = Date()
        let horizon = now.addingTimeInterval(TimeInterval(max(config.dueLookaheadDays, 1)) * 86_400)

        if eventsAllowed {
            let calendars = store.calendars(for: .event).filter { !config.ignoreCalendars.contains($0.title) }
            status.calendars = calendars.map(\.title).sorted()
            let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600), end: horizon, calendars: calendars)
            for event in store.events(matching: predicate) where event.status != .canceled {
                if Self.declinedByMe(event) { continue }
                let title = event.title ?? "Event"
                let calendarTitle = event.calendar?.title ?? ""
                let color = Color(nsColor: event.calendar?.color ?? .systemBlue)
                let id = (event.eventIdentifier ?? UUID().uuidString) + "@\(event.startDate.timeIntervalSince1970)"
                switch CalendarClassifier.classify(title: title, calendarTitle: calendarTitle, start: event.startDate,
                                                   end: event.endDate, isAllDay: event.isAllDay, extraLMS: config.assignmentCalendars) {
                case .due:
                    let due = event.isAllDay
                        ? (Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: event.startDate) ?? event.startDate)
                        : event.startDate
                    guard due > now.addingTimeInterval(-3 * 86_400) else { continue }
                    schedule.due.append(DueItem(id: id, title: Self.cleanDueTitle(title), due: due, source: calendarTitle, color: color))
                case .event:
                    guard event.endDate > now, event.startDate < now.addingTimeInterval(48 * 3600) else { continue }
                    schedule.events.append(CalEvent(
                        id: id,
                        title: title,
                        start: event.startDate,
                        end: event.endDate,
                        location: event.location.flatMap { $0.isEmpty ? nil : $0.components(separatedBy: "\n").first },
                        calendar: calendarTitle,
                        color: color,
                        joinURL: Self.joinURL(for: event)
                    ))
                case .skip:
                    continue
                }
            }
        }

        guard remindersAllowed else {
            publish(schedule, status: status)
            return
        }
        let lists = store.calendars(for: .reminder).filter {
            config.reminderLists.isEmpty || config.reminderLists.contains($0.title)
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: now.addingTimeInterval(-3 * 86_400), ending: horizon, calendars: lists)
        let base = schedule
        _ = store.fetchReminders(matching: predicate) { [weak self] reminders in
            var result = base
            for reminder in reminders ?? [] {
                guard let components = reminder.dueDateComponents,
                      let due = Calendar.current.date(from: components) else { continue }
                // Date-only reminders count as due at the end of that day.
                let dueDate = components.hour != nil ? due : Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: due) ?? due
                result.due.append(DueItem(
                    id: reminder.calendarItemIdentifier,
                    title: reminder.title ?? "Reminder",
                    due: dueDate,
                    source: reminder.calendar?.title ?? "Reminders",
                    color: Color(nsColor: reminder.calendar?.color ?? .systemOrange)
                ))
            }
            self?.publish(result, status: status)
        }
    }

    /// "Lab 5 Report - Due" → "Lab 5 Report"
    static func cleanDueTitle(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: #"\s*[-–:]\s*(due|availability ends|deadline)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return cleaned.isEmpty ? title : cleaned
    }

    private func publish(_ schedule: Schedule, status: CalendarStatus) {
        var sorted = schedule
        sorted.events.sort { $0.start < $1.start }
        sorted.due.sort { $0.due < $1.due }
        var status = status
        status.classCount = sorted.events.count
        status.dueCount = sorted.due.count
        let callback = onUpdate
        let statusCallback = onStatus
        let finalStatus = status
        Task { @MainActor in
            callback?(sorted)
            statusCallback?(finalStatus)
        }
    }

    private static func declinedByMe(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined
    }

    /// Finds a video-call link in the event's URL, location, or notes.
    private static func joinURL(for event: EKEvent) -> URL? {
        if let url = event.url, isJoinLink(url) { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            if let url = match.url, isJoinLink(url) { return url }
        }
        return nil
    }

    private static func isJoinLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return joinHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Only touched from the main thread and its own completion callbacks.
extension CalendarMonitor: @unchecked Sendable {}
