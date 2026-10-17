import XCTest
@testable import Cove

final class QuickTimerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    /// 10:00 local time on a fixed day.
    private var morning: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 10, minute: 0))!
    }

    private func parse(_ text: String, at now: Date? = nil) -> TimeInterval? {
        QuickTimer.parse(text, now: now ?? morning, calendar: calendar)
    }

    // MARK: Parser

    func testBareNumbersAreMinutes() {
        XCTAssertEqual(parse("3"), 180)
        XCTAssertEqual(parse(" 25 "), 1500)
        XCTAssertEqual(parse("1.5"), 90)
    }

    func testUnits() {
        XCTAssertEqual(parse("90s"), 90)
        XCTAssertEqual(parse("45 sec"), 45)
        XCTAssertEqual(parse("1h 15m"), 4500)
        XCTAssertEqual(parse("1h15m"), 4500)
        XCTAssertEqual(parse("1H 15M"), 4500)
        XCTAssertEqual(parse("2 hours and 5 minutes"), 7500)
        XCTAssertEqual(parse("1.5h"), 5400)
        XCTAssertEqual(parse("10 min"), 600)
        XCTAssertEqual(parse("1m 30s"), 90)
    }

    func testHoursMinutesSeconds() {
        XCTAssertEqual(parse("1:15:00"), 4500)
        XCTAssertEqual(parse("0:00:30"), 30)
        XCTAssertNil(parse("1:75:00"))
    }

    func testClockTimesCountDownToTheNextOne() {
        // 10:00 → 12:30 is 2.5 hours away (just after noon).
        XCTAssertEqual(parse("12:30"), 2.5 * 3600)
        XCTAssertEqual(parse("10:45"), 45 * 60)
        // 9:30 has passed this morning, so it means 9:30 tonight.
        XCTAssertEqual(parse("9:30"), 11.5 * 3600)
        XCTAssertEqual(parse("9:30am"), 23.5 * 3600)
        XCTAssertEqual(parse("1:05 pm"), 3 * 3600 + 5 * 60)
        XCTAssertEqual(parse("7pm"), 9 * 3600)
        XCTAssertEqual(parse("17:45"), 7.75 * 3600)
        // Late in the evening, 12:30 is just after midnight.
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 23, minute: 0))!
        XCTAssertEqual(parse("12:30", at: evening), 1.5 * 3600)
    }

    func testRejectsNonsense() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("soon"))
        XCTAssertNil(parse("5 parsecs"))
        XCTAssertNil(parse("1h 15"))
        XCTAssertNil(parse("0"))
        XCTAssertNil(parse("-5"))
        XCTAssertNil(parse("25:00"))
        XCTAssertNil(parse("13pm"))
        XCTAssertNil(parse("25h"))   // longer than a day
    }

    // MARK: Countdown

    func testRemainingPauseAndResume() {
        let start = morning
        var timer = QuickTimer.start(seconds: 300, label: "Timer", now: start)
        XCTAssertEqual(timer.remaining(at: start), 300)
        XCTAssertEqual(QuickTimer.clock(timer.remaining(at: start)), "5:00")
        XCTAssertEqual(QuickTimer.clock(timer.remaining(at: start.addingTimeInterval(0.4))), "5:00")
        XCTAssertEqual(QuickTimer.clock(timer.remaining(at: start.addingTimeInterval(61))), "3:59")
        XCTAssertEqual(timer.fractionLeft(at: start.addingTimeInterval(150)), 0.5, accuracy: 0.001)

        timer = timer.paused(at: start.addingTimeInterval(100))
        XCTAssertTrue(timer.isPaused)
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(5000)), 200)
        timer = timer.resumed(at: start.addingTimeInterval(1000))
        XCTAssertEqual(timer.endDate, start.addingTimeInterval(1200))
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(2000)), 0)
    }

    func testClockAndNames() {
        XCTAssertEqual(QuickTimer.clock(0), "0:00")
        XCTAssertEqual(QuickTimer.clock(754), "12:34")
        XCTAssertEqual(QuickTimer.clock(4500), "1:15:00")
        XCTAssertEqual(QuickTimer.name(90), "1 min 30 sec")
        XCTAssertEqual(QuickTimer.name(600), "10 min")
        XCTAssertEqual(QuickTimer.name(4500), "1 hr 15 min")
        XCTAssertEqual(QuickTimer.name(45), "45 sec")
    }

    // MARK: Persistence

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "CoveTimerTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testStoreRoundTrips() {
        let store = QuickTimerStore(defaults: defaults)
        XCTAssertNil(store.load())
        let timer = QuickTimer.start(seconds: 600, label: "Focus", now: morning)
        store.save(timer)
        XCTAssertEqual(QuickTimerStore(defaults: defaults).load(), timer)
        let paused = timer.paused(at: morning.addingTimeInterval(60))
        store.save(paused)
        XCTAssertEqual(QuickTimerStore(defaults: defaults).load(), paused)
        store.save(nil)
        XCTAssertNil(QuickTimerStore(defaults: defaults).load())
    }

    @MainActor
    private func makeModel() -> IslandModel {
        var config = CoveConfig()
        config.sounds = false
        config.calendar = false
        config.buddyAlwaysVisible = false
        return IslandModel(config: config, timerStore: QuickTimerStore(defaults: defaults))
    }

    @MainActor
    func testRunningTimerSurvivesRestart() throws {
        let first = makeModel()
        XCTAssertTrue(first.startTimer(text: "1h 15m"))
        let timer = try XCTUnwrap(first.timer)
        XCTAssertEqual(timer.label, "Timer")
        XCTAssertEqual(timer.total, 4500)
        XCTAssertEqual(first.compactItem, .timer(timer))

        // A new model (Cove relaunched) picks up the same end date.
        let second = makeModel()
        XCTAssertEqual(second.timer?.endDate, timer.endDate)
        XCTAssertEqual(second.presentation, .compact)

        second.pauseTimer()
        XCTAssertEqual(makeModel().timer?.isPaused, true)
        second.resumeTimer()
        XCTAssertEqual(makeModel().timer?.isPaused, false)
        second.cancelTimer()
        XCTAssertNil(makeModel().timer)
        XCTAssertNil(second.compactItem)
        first.cancelTimer()
    }

    @MainActor
    func testTimerThatEndedWhileClosedRingsOnLaunch() {
        let ended = QuickTimer(label: "Timer", total: 300, endDate: Date().addingTimeInterval(-120), pausedRemaining: nil)
        QuickTimerStore(defaults: defaults).save(ended)
        let relaunched = makeModel()
        XCTAssertNil(relaunched.timer)
        XCTAssertEqual(relaunched.banner?.title, "Time's up")
        XCTAssertNil(QuickTimerStore(defaults: defaults).load())
    }

    @MainActor
    func testFocusStillWorksThroughTheTimer() {
        let model = makeModel()
        model.startFocus(minutes: 25)
        XCTAssertEqual(model.timer?.label, "Focus")
        XCTAssertEqual(model.timer?.total, 1500)
        XCTAssertFalse(model.startTimer(text: "nope"))
        XCTAssertEqual(model.timer?.label, "Focus")
        model.stopFocus()
        XCTAssertNil(model.timer)
    }

    @MainActor
    func testShortTimerRingsAtZero() async throws {
        let model = makeModel()
        model.startTimer(seconds: 1)
        for _ in 0..<60 where model.timer != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(model.timer)
        XCTAssertEqual(model.banner?.title, "Time's up")
        XCTAssertEqual(model.banner?.icon, .buddy(.happy, nil))
        XCTAssertNil(QuickTimerStore(defaults: defaults).load())
    }
}
