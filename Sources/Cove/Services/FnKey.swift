import AppKit

/// Hold fn (🌐) to talk, let go to send. The rules live here, apart from the event plumbing, so the
/// timing is testable:
/// - a quick tap does nothing (macOS may use it for the emoji picker or dictation);
/// - fn used as a modifier (fn+arrow, fn+F5, fn+⌘) never starts listening;
/// - Esc while listening cancels.
struct FnHoldGesture {
    enum Action: Equatable { case none, begin, end, cancel }

    /// How long fn has to be held, alone, before Cove starts listening.
    static let holdDelay: TimeInterval = 0.25

    private(set) var pressedAt: Date?
    private(set) var spoiled = false
    private(set) var active = false

    /// fn went down or up. `otherModifiers`: ⌘, ⌥, ⌃ or ⇧ were already held.
    mutating func fn(down: Bool, otherModifiers: Bool, at now: Date) -> Action {
        if down {
            guard pressedAt == nil else { return .none }
            pressedAt = now
            spoiled = otherModifiers
            active = false
            return .none
        }
        let wasActive = active
        pressedAt = nil
        spoiled = false
        active = false
        return wasActive ? .end : .none
    }

    /// Another key or modifier while fn is down: before listening starts, fn is being used as a modifier.
    /// Once listening, other keys are left alone.
    mutating func otherInput() -> Action {
        guard pressedAt != nil, !active else { return .none }
        spoiled = true
        return .none
    }

    /// Called `holdDelay` after fn went down.
    mutating func holdElapsed(at now: Date) -> Action {
        guard let pressedAt, !spoiled, !active, now.timeIntervalSince(pressedAt) >= Self.holdDelay - 0.01 else { return .none }
        active = true
        return .begin
    }

    /// Esc: stop listening without sending. Releasing fn afterwards does nothing.
    mutating func escape() -> Action {
        guard active else { return .none }
        active = false
        spoiled = true
        return .cancel
    }
}

/// Watches the fn key system-wide and turns it into begin / end / cancel. Watching keys in other apps
/// needs Accessibility; without it only presses while Cove itself is in front arrive.
@MainActor
final class FnKeyMonitor {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var onCancel: (() -> Void)?

    private var gesture = FnHoldGesture()
    private var monitors: [Any] = []
    private var holdWork: DispatchWorkItem?
    private var fnDown = false

    var isRunning: Bool { !monitors.isEmpty }
    static var hasAccess: Bool { MediaKeyTap.isTrusted }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        // Both monitors call back on the main thread.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        holdWork?.cancel()
        holdWork = nil
        if gesture.active { onCancel?() }
        gesture = FnHoldGesture()
        fnDown = false
    }

    private func handle(_ event: NSEvent) {
        let now = Date()
        switch event.type {
        case .flagsChanged:
            // Only modifier keys send flagsChanged, so a change in the fn flag is the fn key itself
            // (whatever key code a given keyboard uses for 🌐).
            let flags = event.modifierFlags
            let down = flags.contains(.function)
            if down != fnDown {
                fnDown = down
                let others = !flags.intersection([.command, .option, .control, .shift]).isEmpty
                perform(gesture.fn(down: down, otherModifiers: others, at: now))
                holdWork?.cancel()
                if down { scheduleHold() }
            } else {
                perform(gesture.otherInput())
            }
        case .keyDown:
            if event.keyCode == 53 { perform(gesture.escape()) }   // kVK_Escape
            else { perform(gesture.otherInput()) }
        default:
            break
        }
    }

    private func scheduleHold() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.perform(self.gesture.holdElapsed(at: Date()))
            }
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FnHoldGesture.holdDelay, execute: work)
    }

    private func perform(_ action: FnHoldGesture.Action) {
        switch action {
        case .begin: onBegin?()
        case .end: onEnd?()
        case .cancel: onCancel?()
        case .none: break
        }
    }
}
