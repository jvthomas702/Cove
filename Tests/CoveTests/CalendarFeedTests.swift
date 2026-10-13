import SwiftUI
import XCTest
@testable import Cove

/// Feeds shaped like the real ones: Google Calendar's "secret address in iCal format" and a D2L
/// Brightspace calendar subscription.
final class ICSParserTests: XCTestCase {
    static let google = """
    BEGIN:VCALENDAR
    PRODID:-//Google Inc//Google Calendar 70.9054//EN
    VERSION:2.0
    CALSCALE:GREGORIAN
    METHOD:PUBLISH
    X-WR-CALNAME:KSU Classes
    X-WR-TIMEZONE:America/New_York
    BEGIN:VTIMEZONE
    TZID:America/New_York
    X-LIC-LOCATION:America/New_York
    BEGIN:DAYLIGHT
    TZOFFSETFROM:-0500
    TZOFFSETTO:-0400
    TZNAME:EDT
    DTSTART:19700308T020000
    RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU
    END:DAYLIGHT
    BEGIN:STANDARD
    TZOFFSETFROM:-0400
    TZOFFSETTO:-0500
    TZNAME:EST
    DTSTART:19701101T020000
    RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU
    END:STANDARD
    END:VTIMEZONE
    BEGIN:VEVENT
    DTSTART;TZID=America/New_York:20260825T093000
    DTEND;TZID=America/New_York:20260825T104500
    RRULE:FREQ=WEEKLY;WKST=SU;UNTIL=20261210T035959Z;BYDAY=TH,TU
    EXDATE;TZID=America/New_York:20261124T093000
    DTSTAMP:20261012T120000Z
    UID:cpe3000@google.com
    SUMMARY:CPE 3000 Lecture
    LOCATION:Atrium Building\\, Room 210\\nMarietta
    DESCRIPTION:Office hours on Zoom: https://kennesaw.zoom.us/j/123456
     789
    STATUS:CONFIRMED
    BEGIN:VALARM
    ACTION:DISPLAY
    DESCRIPTION:This is an event reminder
    TRIGGER:-P0DT0H10M0S
    END:VALARM
    END:VEVENT
    BEGIN:VEVENT
    DTSTART;TZID=America/New_York:20261015T110000
    DTEND;TZID=America/New_York:20261015T121500
    RECURRENCE-ID;TZID=America/New_York:20261015T093000
    UID:cpe3000@google.com
    SUMMARY:CPE 3000 Lecture (moved to 11)
    END:VEVENT
    BEGIN:VEVENT
    DTSTART;TZID=America/New_York:20261020T093000
    DTEND;TZID=America/New_York:20261020T104500
    RECURRENCE-ID;TZID=America/New_York:20261020T093000
    UID:cpe3000@google.com
    STATUS:CANCELLED
    SUMMARY:CPE 3000 Lecture
    END:VEVENT
    BEGIN:VEVENT
    DTSTART;VALUE=DATE:20261012
    DTEND;VALUE=DATE:20261013
    UID:holiday@google.com
    SUMMARY:Fall break
    END:VEVENT
    BEGIN:VEVENT
    DTSTART:20261014T180000Z
    DTEND:20261014T190000Z
    UID:dropped@google.com
    STATUS:CANCELLED
    SUMMARY:Cancelled club meeting
    END:VEVENT
    END:VCALENDAR
    """

    static let d2l = [
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Desire2Learn Inc//D2L Calendar//EN", "X-WR-CALNAME:Jason Thomas",
        "BEGIN:VEVENT", "UID:d2l-1", "DTSTAMP:20261012T120000Z", "DTSTART:20261014T035900Z", "DTEND:20261014T035900Z",
        "SUMMARY:Lab 5 Report - Due", "LOCATION:CPE 3000 Computer Systems", "END:VEVENT",
        "BEGIN:VEVENT", "UID:d2l-2", "DTSTART:20261016T040000Z", "DTEND:20261016T040000Z",
        "SUMMARY:Quiz 3 - Availability Ends", "END:VEVENT",
        "BEGIN:VEVENT", "UID:d2l-3", "DTSTART:20261015T140000Z", "DURATION:PT1H15M",
        "SUMMARY:Exam 2 Review Session", "END:VEVENT",
        "END:VCALENDAR",
    ].joined(separator: "\r\n")

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, zone: String = "America/New_York") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func lectures(from: Date, to: Date) -> [ICSOccurrence] {
        ICSParser.occurrences(in: Self.google, from: from, to: to).filter { $0.uid == "cpe3000@google.com" }
    }

    func testCalendarName() {
        XCTAssertEqual(ICSParser.calendarName(Self.google), "KSU Classes")
        XCTAssertEqual(ICSParser.calendarName(Self.d2l), "Jason Thomas")
    }

    func testWeeklyClassWithMovedAndCancelledInstances() {
        let items = lectures(from: date(2026, 10, 12), to: date(2026, 10, 31))
        XCTAssertEqual(items.map(\.start), [
            date(2026, 10, 13, 9, 30),
            date(2026, 10, 15, 11, 0),   // moved
            // Oct 20 cancelled
            date(2026, 10, 22, 9, 30),
            date(2026, 10, 27, 9, 30),
            date(2026, 10, 29, 9, 30),
        ])
        XCTAssertEqual(items[1].title, "CPE 3000 Lecture (moved to 11)")
        XCTAssertEqual(items[0].end.timeIntervalSince(items[0].start), 75 * 60)
        XCTAssertEqual(items[0].location, "Atrium Building, Room 210\nMarietta")
        XCTAssertEqual(items[0].notes, "Office hours on Zoom: https://kennesaw.zoom.us/j/123456789", "folded line, and VALARM's text ignored")
        XCTAssertEqual(CalendarMonitor.findJoinURL(in: items[0].notes ?? "")?.absoluteString, "https://kennesaw.zoom.us/j/123456789")
    }

    func testClassKeepsLocalTimeAcrossDaylightSavingAndHonorsExdateAndUntil() {
        let items = lectures(from: date(2026, 11, 1), to: date(2026, 12, 31))
        XCTAssertEqual(items.first?.start, date(2026, 11, 3, 9, 30), "9:30 EST after the clocks change")
        XCTAssertEqual(date(2026, 11, 3, 9, 30), date(2026, 11, 3, 14, 30, zone: "UTC"))
        XCTAssertFalse(items.contains { $0.start == date(2026, 11, 24, 9, 30) }, "EXDATE (Thanksgiving week)")
        XCTAssertEqual(items.last?.start, date(2026, 12, 8, 9, 30), "UNTIL ends the series before Dec 10")
    }

    func testAllDayAndCancelledEvents() {
        let items = ICSParser.occurrences(in: Self.google, from: date(2026, 10, 12), to: date(2026, 10, 16))
        let fallBreak = items.first { $0.title == "Fall break" }
        XCTAssertEqual(fallBreak?.isAllDay, true)
        XCTAssertFalse(items.contains { $0.title == "Cancelled club meeting" })
    }

    func testD2LFeedItems() {
        let items = ICSParser.occurrences(in: Self.d2l, from: date(2026, 10, 12), to: date(2026, 10, 20))
        XCTAssertEqual(items.map(\.title), ["Lab 5 Report - Due", "Exam 2 Review Session", "Quiz 3 - Availability Ends"])
        XCTAssertEqual(items[0].start, items[0].end)
        XCTAssertEqual(items[0].start, date(2026, 10, 13, 23, 59), "11:59 PM Eastern")
        XCTAssertEqual(items[1].end.timeIntervalSince(items[1].start), 75 * 60, "DURATION")

        // Classified the way the feed monitor does it.
        let url = ICSFeedMonitor.normalize("https://kennesaw.view.usg.edu/d2l/le/calendar/feed/user/feed.ics?token=abc")!
        let name = ICSFeedMonitor.displayName("Jason Thomas", url: url)
        XCTAssertEqual(name, "D2L")
        let kinds = items.map {
            CalendarClassifier.classify(title: $0.title, calendarTitle: "\(name) D2L", start: $0.start, end: $0.end,
                                        isAllDay: $0.isAllDay, extraLMS: [])
        }
        XCTAssertEqual(kinds, [.due, .event, .due])
    }

    func testRecurrenceEdges() {
        let start = ICSParser.ParsedDate(date: date(2026, 10, 12, 8), dateOnly: false, timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(ICSParser.expand(rule: "FREQ=DAILY;COUNT=3", start: start, until: date(2027, 1, 1)).count, 3)
        XCTAssertEqual(ICSParser.expand(rule: "FREQ=WEEKLY;INTERVAL=2", start: start, until: date(2026, 11, 10)).count, 3)
        XCTAssertEqual(ICSParser.expand(rule: "FREQ=DAILY;UNTIL=20261014", start: start, until: date(2027, 1, 1)).count, 3,
                       "a date-only UNTIL includes that day")
        // A weekly series that began years ago still shows this week.
        let old = ICSParser.ParsedDate(date: date(2019, 1, 7, 10), dateOnly: false, timeZone: TimeZone(identifier: "America/New_York")!)
        let recent = ICSParser.expand(rule: "FREQ=WEEKLY;BYDAY=MO", start: old, from: date(2026, 10, 12), until: date(2026, 10, 20))
        XCTAssertEqual(recent.filter { $0 >= date(2026, 10, 12) }, [date(2026, 10, 12, 10), date(2026, 10, 19, 10)])
    }

    func testDurations() {
        XCTAssertEqual(ICSParser.parseDuration("PT1H30M"), 5400)
        XCTAssertEqual(ICSParser.parseDuration("P1DT2H"), 93_600)
        XCTAssertEqual(ICSParser.parseDuration("-PT15M"), -900)
        XCTAssertNil(ICSParser.parseDuration("1H"))
    }
}

final class CalendarLinkTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(ICSFeedMonitor.normalize("webcal://p52-caldav.icloud.com/published/2/abc")?.absoluteString,
                       "https://p52-caldav.icloud.com/published/2/abc")
        XCTAssertEqual(ICSFeedMonitor.normalize("  http://example.edu/feed.ics \n")?.scheme, "https")
        XCTAssertEqual(ICSFeedMonitor.normalize("http://127.0.0.1:8765/feed.ics")?.scheme, "http")
        XCTAssertNil(ICSFeedMonitor.normalize("my calendar"))
        XCTAssertNil(ICSFeedMonitor.normalize("ftp://example.com/feed.ics"))
    }

    func testFriendlyNames() {
        XCTAssertEqual(ICSFeedMonitor.friendlyName(URL(string: "https://calendar.google.com/calendar/ical/x/private-y/basic.ics")!), "Google Calendar")
        XCTAssertEqual(ICSFeedMonitor.friendlyName(URL(string: "https://kennesaw.view.usg.edu/d2l/le/calendar/feed/user/feed.ics")!), "D2L")
        XCTAssertEqual(ICSFeedMonitor.displayName("KSU Classes", url: URL(string: "https://calendar.google.com/x.ics")!), "KSU Classes")
    }

    func testCatchesWrongLinks() {
        XCTAssertNotNil(SettingsController.feedProblem("https://calendar.google.com/calendar/u/0/r"))
        XCTAssertNotNil(SettingsController.feedProblem("https://calendar.google.com/calendar/embed?src=me%40gmail.com"))
        XCTAssertNil(SettingsController.feedProblem("https://calendar.google.com/calendar/ical/me%40gmail.com/private-abc/basic.ics"))
        XCTAssertNotNil(SettingsController.feedProblem("https://kennesaw.view.usg.edu/d2l/le/calendar/6606"))
        XCTAssertNil(SettingsController.feedProblem("https://kennesaw.view.usg.edu/d2l/le/calendar/feed/user/feed.ics?token=abc"))
        XCTAssertNotNil(SettingsController.feedProblem("not a link"))
    }

    func testMergeDropsDuplicates() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let lecture = CalEvent(id: "a", title: "CPE 3000 Lecture", start: start, end: start.addingTimeInterval(4500),
                               location: nil, calendar: "Calendar", color: .blue, joinURL: nil)
        var copy = lecture
        copy.calendar = "KSU Classes"
        let due = DueItem(id: "d", title: "Lab 5 Report", due: start, source: "D2L", color: .red)
        let merged = Schedule.merged([Schedule(events: [lecture], due: [due]), Schedule(events: [copy], due: [due])])
        XCTAssertEqual(merged.events.count, 1)
        XCTAssertEqual(merged.due.count, 1)
    }
}

@MainActor
final class ScheduleSetupTests: XCTestCase {
    private func makeModel() -> IslandModel {
        var config = CoveConfig()
        config.sounds = false
        config.calendar = true
        return IslandModel(config: config)
    }

    func testAsksToConnectWhenNothingIsSetUp() {
        let model = makeModel()
        XCTAssertEqual(model.scheduleSetup?.pane, .features)

        model.calendarStatus = CalendarStatus(access: .granted, calendars: ["Home", "Work", "US Holidays"])
        XCTAssertNotNil(model.scheduleSetup, "only the built-in calendars: D2L and Google aren't connected")

        model.calendarStatus = CalendarStatus(access: .granted, calendars: ["Home", "jason@example.com"])
        XCTAssertNil(model.scheduleSetup)
    }

    func testFeedStates() {
        let model = makeModel()
        model.feedStatuses = [FeedStatus(url: "https://x/feed.ics", name: "D2L", state: .loading)]
        XCTAssertEqual(model.scheduleSetup?.title, "Loading your calendars…")
        model.feedStatuses = [FeedStatus(url: "https://x/feed.ics", name: "D2L", state: .ok)]
        XCTAssertNil(model.scheduleSetup)
        model.feedStatuses = [FeedStatus(url: "https://x/feed.ics", name: "D2L", state: .failed("Link not found"))]
        XCTAssertEqual(model.scheduleSetup?.title, "D2L link didn't load")
        XCTAssertEqual(model.scheduleSetup?.detail, "Link not found")
    }
}
