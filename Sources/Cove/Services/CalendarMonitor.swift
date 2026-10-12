import AppKit
import EventKit
import SwiftUI

/// Reads your Mac's Calendar (classes, meetings) and Reminders (due dates) via EventKit.
///
/// Assignment feeds: subscribe to your LMS calendar (D2L/Brightspace, Canvas, Gradescope…) in the
/// Calendar app. Events from calendars with those names — or listed in `assignmentCalendars` —
/// are treated as due dates instead of meetings.
final class CalendarMonitor {
    var onUpdate: (@MainActor (Schedule) -> Void)?
    var onAccessDenied: (@MainActor () -> Void)?

    private let store = EKEventStore()
    private var config: CoveConfig
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var eventsAllowed = false
    private var remindersAllowed = false

    private static let assignmentHints = ["canvas", "d2l", "brightspace", "gradescope", "assignment", "blackboard", "moodle", "due"]
    private static let joinHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com"]

    init(config: CoveConfig) {
        self.config = config
    }

    func update(config: CoveConfig) {
        self.config = config
        refresh()
    }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            let events = (try? await self.store.requestFullAccessToEvents()) ?? false
            let reminders = (try? await self.store.requestFullAccessToReminders()) ?? false
            self.eventsAllowed = events
            self.remindersAllowed = reminders
            if !events && !reminders {
                let denied = self.onAccessDenied
                await MainActor.run { denied?() }
                return
            }
            await MainActor.run { self.begin() }
        }
    }

    @MainActor
    private func begin() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        // Re-read every 5 minutes; the countdown text itself updates on its own.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func refresh() {
        let config = self.config
        var schedule = Schedule()
        let now = Date()

        if eventsAllowed {
            let calendars = store.calendars(for: .event).filter { !config.ignoreCalendars.contains($0.title) }
            let horizon = now.addingTimeInterval(TimeInterval(max(config.dueLookaheadDays, 1)) * 86_400)
            let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: horizon, calendars: calendars)
            for event in store.events(matching: predicate) where event.status != .canceled {
                if Self.declinedByMe(event) { continue }
                let calendarTitle = event.calendar?.title ?? ""
                let color = Color(nsColor: event.calendar?.color ?? .systemBlue)
                let id = (event.eventIdentifier ?? UUID().uuidString) + "@\(event.startDate.timeIntervalSince1970)"
                if Self.isAssignmentCalendar(calendarTitle, config: config) {
                    // LMS feeds mark the due moment as the event's start.
                    schedule.due.append(DueItem(id: id, title: event.title ?? "Assignment", due: event.startDate, source: calendarTitle, color: color))
                } else if !event.isAllDay, event.startDate < now.addingTimeInterval(36 * 3600) {
                    schedule.events.append(CalEvent(
                        id: id,
                        title: event.title ?? "Event",
                        start: event.startDate,
                        end: event.endDate,
                        location: event.location.flatMap { $0.isEmpty ? nil : $0 },
                        calendar: calendarTitle,
                        color: color,
                        joinURL: Self.joinURL(for: event)
                    ))
                }
            }
        }

        guard remindersAllowed else {
            publish(schedule)
            return
        }
        let lists = store.calendars(for: .reminder).filter {
            config.reminderLists.isEmpty || config.reminderLists.contains($0.title)
        }
        let horizon = now.addingTimeInterval(TimeInterval(max(config.dueLookaheadDays, 1)) * 86_400)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: now.addingTimeInterval(-3 * 86_400), ending: horizon, calendars: lists)
        let base = schedule
        _ = store.fetchReminders(matching: predicate) { [weak self] reminders in
            var result = base
            for reminder in reminders ?? [] {
                guard let components = reminder.dueDateComponents,
                      let due = Calendar.current.date(from: components) else { continue }
                // Date-only reminders count as due at the end of that day.
                let hasTime = components.hour != nil
                let dueDate = hasTime ? due : Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: due) ?? due
                result.due.append(DueItem(
                    id: reminder.calendarItemIdentifier,
                    title: reminder.title ?? "Reminder",
                    due: dueDate,
                    source: reminder.calendar?.title ?? "Reminders",
                    color: Color(nsColor: reminder.calendar?.color ?? .systemOrange)
                ))
            }
            self?.publish(result)
        }
    }

    private func publish(_ schedule: Schedule) {
        var sorted = schedule
        sorted.events.sort { $0.start < $1.start }
        sorted.due.sort { $0.due < $1.due }
        let callback = onUpdate
        Task { @MainActor in callback?(sorted) }
    }

    private static func isAssignmentCalendar(_ title: String, config: CoveConfig) -> Bool {
        if config.assignmentCalendars.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) { return true }
        let lower = title.lowercased()
        return assignmentHints.contains { lower.contains($0) }
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
