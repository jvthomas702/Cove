import AppKit
import ApplicationServices
import Foundation

/// Only app window titles and composer button metadata are read. No chat database, screenshots,
/// text-field values, or hidden reasoning are accessed.
enum DesktopAIControls {
    enum Observation: Equatable { case working, ready, unavailable }
    static func classify(buttons: [String], hasComposer: Bool) -> Observation {
        let labels = buttons.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let stopLabels = ["stop generating", "stop streaming", "stop response", "stop replying", "stop task", "stop turn", "stop current task", "stop current response"]
        if labels.contains(where: { label in
            stopLabels.contains(where: { label.contains($0) }) || (hasComposer && label == "stop")
        }) { return .working }
        if hasComposer && labels.contains(where: { label in
            ["send", "send message", "send prompt", "submit prompt", "send-button"].contains(label)
                || label.hasPrefix("send message ") || label.hasPrefix("send prompt ")
        }) { return .ready }
        return .unavailable
    }
}

struct DesktopAIWindow {
    var id: String
    var title: String
    var app: String
    var observation: DesktopAIControls.Observation
}

/// Two consistent observations are required for either transition. An unreadable UI cannot finish a task.
struct DesktopAITracker {
    private struct State {
        var busySamples = 0
        var readySamples = 0
        var missingSamples = 0
        var active = false
        var window: DesktopAIWindow
    }
    private var states: [String: State] = [:]

    mutating func poll(_ windows: [DesktopAIWindow]) -> [CoveEvent] {
        var events: [CoveEvent] = []
        let present = Set(windows.map(\.id))
        for window in windows {
            var state = states[window.id] ?? State(window: window)
            // Switching chats in the same window is not a completion of the previous chat.
            if state.window.title != window.title {
                if state.active { events.append(event(state.window, kind: "clear", body: "Chat changed", phase: nil)) }
                state = State(window: window)
            }
            state.window = window
            state.missingSamples = 0
            switch window.observation {
            case .working:
                state.readySamples = 0
                state.busySamples += 1
                if state.busySamples >= 2 {
                    state.active = true
                    events.append(event(window, kind: "running", body: "ChatGPT is working in the desktop app", phase: "Generating response"))
                }
            case .ready:
                state.busySamples = 0
                state.readySamples += 1
                if state.active && state.readySamples >= 2 {
                    state.active = false
                    events.append(event(window, kind: "done", body: "Response finished in ChatGPT. Open the app to read it.", phase: "Finished", silent: true))
                }
            case .unavailable:
                state.busySamples = 0
                state.readySamples = 0
                if state.active {
                    events.append(event(window, kind: "running", body: "Last seen working; the app's controls are currently unavailable", phase: "Status unavailable"))
                }
            }
            states[window.id] = state
        }
        for id in Array(states.keys) where !present.contains(id) {
            guard var state = states[id] else { continue }
            state.missingSamples += 1
            if state.missingSamples >= 2 {
                if state.active { events.append(event(state.window, kind: "clear", body: "Window closed", phase: nil)) }
                states[id] = nil
            } else { states[id] = state }
        }
        return events
    }

    mutating func reset() -> [CoveEvent] {
        let events = states.values.filter(\.active).map { event($0.window, kind: "clear", body: "Monitoring unavailable", phase: nil) }
        states.removeAll()
        return events
    }

    private func event(_ window: DesktopAIWindow, kind: String, body: String, phase: String?, silent: Bool = false) -> CoveEvent {
        CoveEvent(app: window.app, id: "desktop:chatgpt:\(window.id)", title: window.title.oneLine(max: 90),
                  body: body, kind: kind, source: "chatgpt", phase: phase, silent: silent)
    }
}

/// Probe state is confined to one utility queue; slow Accessibility calls never block the notch UI.
private final class DesktopAIProbe {
    static let bundleIDs = ["com.openai.chat", "com.openai.codex"]
    private var tracker = DesktopAITracker()

    func sample() -> (String, [CoveEvent]) {
        guard AXIsProcessTrusted() else { return ("Allow Accessibility to follow the ChatGPT app", tracker.reset()) }
        let apps = Self.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        guard !apps.isEmpty else { return ("Waiting for the ChatGPT app", tracker.reset()) }
        var windows: [DesktopAIWindow] = []
        var complete = true
        for app in apps {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.15)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let appWindows = value as? [AXUIElement] else { complete = false; continue }
            for window in appWindows.prefix(8) {
                let title = string(window, kAXTitleAttribute) ?? "ChatGPT"
                windows.append(DesktopAIWindow(id: "\(app.processIdentifier):\(CFHash(window))", title: title.isEmpty ? "ChatGPT" : title,
                                               app: app.bundleIdentifier ?? "com.openai.chat", observation: observe(window)))
            }
        }
        // Failed enumeration is not evidence that an active chat window was closed.
        guard complete else { return ("ChatGPT controls unavailable; waiting to reconnect", []) }
        let supported = windows.contains { $0.observation != .unavailable }
        return (supported ? "Following visible ChatGPT windows" : "ChatGPT controls unavailable; keep its chat window open", tracker.poll(windows))
    }

    private func observe(_ window: AXUIElement) -> DesktopAIControls.Observation {
        var pending: [(AXUIElement, Int)] = [(window, 0)]
        var labels: [String] = []
        var hasComposer = false
        var index = 0
        while index < pending.count && index < 800 {
            let (element, depth) = pending[index]
            index += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == kAXTextAreaRole || role == kAXTextFieldRole { hasComposer = true }
            if role == kAXButtonRole {
                for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute] {
                    if let label = string(element, attribute), !label.isEmpty { labels.append(label) }
                }
            }
            guard depth < 18 else { continue }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            if result == .cannotComplete { return .unavailable }
            if let children = value as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(max(0, 800 - pending.count)).map { ($0, depth + 1) })
            }
        }
        return DesktopAIControls.classify(buttons: labels, hasComposer: hasComposer)
    }
    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

@MainActor
final class DesktopAIActivityMonitor {
    var onEvent: ((CoveEvent) -> Void)?
    var onStatus: ((String) -> Void)?
    private let queue = DispatchQueue(label: "cove.desktop-ai", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var generation = UUID()
    private var tracked = Set<String>()

    func start(enabled: Bool) {
        stop()
        guard enabled else { onStatus?("ChatGPT app tracking is off"); return }
        onStatus?("Checking ChatGPT app…")
        let token = generation
        let probe = DesktopAIProbe()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            let (status, events) = probe.sample()
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.timer != nil else { return }
                self.onStatus?(status)
                for event in events {
                    if let id = event.id {
                        if event.kind == "running" { self.tracked.insert(id) } else { self.tracked.remove(id) }
                    }
                    self.onEvent?(event)
                }
            }
        }
        self.timer = timer
        timer.resume()
    }
    func stop() {
        generation = UUID()
        timer?.cancel()
        timer = nil
        for id in tracked { onEvent?(CoveEvent(id: id, title: "ChatGPT", kind: "clear")) }
        tracked.removeAll()
    }
}
