import AppKit
import SwiftUI

/// First launch: three short steps instead of a full Settings window.
/// Hello → pick what the island shows → allow only what those picks need.
enum WelcomeStep: Int, CaseIterable {
    case hello, pick, allow
}

/// One thing a new user can turn on from the welcome window, and the permissions it needs.
struct WelcomeFeature: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let permissions: [Permission]
    let isOn: (CoveConfig) -> Bool
    let set: (inout CoveConfig, Bool) -> Void

    static let all: [WelcomeFeature] = [
        WelcomeFeature(id: "calendar", title: "Classes and due dates", detail: "Countdown to your next class, and what's due soon",
                       symbol: "calendar", permissions: [.calendars, .reminders],
                       isOn: { $0.calendar }, set: { $0.calendar = $1 }),
        WelcomeFeature(id: "screenshots", title: "Screenshots on the shelf", detail: "Drag a new screenshot straight out of the notch",
                       symbol: "photo.on.rectangle", permissions: [.desktop],
                       isOn: { $0.screenshotsToShelf }, set: { $0.screenshotsToShelf = $1 }),
        WelcomeFeature(id: "hud", title: "Volume and brightness", detail: "Replaces the macOS pop-up with a small meter in the notch",
                       symbol: "speaker.wave.2.fill", permissions: [.accessibility],
                       isOn: { $0.hud == "replace" }, set: { $0.hud = $1 ? "replace" : "passive" }),
        WelcomeFeature(id: "notifications", title: "Notifications from other apps", detail: "Messages and mail slide out of the notch",
                       symbol: "bell.badge.fill", permissions: [.fullDiskAccess],
                       isOn: { $0.mirrorNotifications }, set: { $0.mirrorNotifications = $1 }),
        WelcomeFeature(id: "sports", title: "Sports scores", detail: "Pin an NBA, NFL or college football game beside the notch",
                       symbol: "sportscourt.fill", permissions: [],
                       isOn: { $0.sportsEnabled }, set: { $0.sportsEnabled = $1 }),
    ]

    /// The permissions the features turned on in `config` need, in Settings order.
    static func neededPermissions(_ config: CoveConfig) -> [Permission] {
        let needed = Set(all.filter { $0.isOn(config) }.flatMap(\.permissions))
        return Permission.allCases.filter(needed.contains)
    }
}

struct WelcomeView: View {
    @ObservedObject var controller: SettingsController
    @ObservedObject private var model: IslandModel
    @Binding var step: WelcomeStep
    let finish: () -> Void

    init(controller: SettingsController, step: Binding<WelcomeStep>, finish: @escaping () -> Void) {
        _controller = ObservedObject(wrappedValue: controller)
        _model = ObservedObject(wrappedValue: controller.model)
        _step = step
        self.finish = finish
    }

    var body: some View {
        VStack(spacing: 0) {
            Buddy(mood: step == .allow ? .working : .happy, size: 56)
                .frame(height: 70)
                .padding(.top, 28)
            Text(title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink)
                .padding(.top, 14)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 40)

            Group {
                switch step {
                case .hello: hello
                case .pick: pick
                case .allow: allow
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 28)
            .padding(.top, 22)

            if let message = controller.message {
                Text(message)
                    .font(.caption).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28).padding(.bottom, 8)
            }
            footer
        }
        .frame(width: 480, height: 620)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private var title: String {
        switch step {
        case .hello: return "Hi, I'm Nori"
        case .pick: return "What should Cove show?"
        case .allow: return permissions.isEmpty ? "You're all set" : "Allow what you picked"
        }
    }

    private var subtitle: String {
        switch step {
        case .hello: return "Cove turns the notch into a little Dynamic Island for your agents, classes and everything else."
        case .pick: return "You can change any of this later in Settings."
        case .allow: return permissions.isEmpty
            ? "Nothing you picked needs a permission."
            : "macOS asks once for each. Everything stays on this Mac."
        }
    }

    // MARK: Steps

    private var hello: some View {
        VStack(spacing: 10) {
            HelloRow(symbol: "sparkles", title: "Your agents, at a glance",
                     detail: "Claude Code and Codex show what they're doing, and ping you when they finish.")
            HelloRow(symbol: "checkmark.shield.fill", title: "Approve from the notch",
                     detail: "Allow or deny Claude Code's permission prompts without switching windows.")
            HelloRow(symbol: "cursorarrow.motionlines", title: "Hover to open",
                     detail: "Move the pointer to the notch to open the island. ⌃⌥Space works too.")
        }
    }

    private var pick: some View {
        VStack(spacing: 8) {
            agentsCard
            ForEach(WelcomeFeature.all) { feature in
                PickRow(feature: feature, isOn: Binding(
                    get: { feature.isOn(model.config) },
                    set: { on in
                        var config = model.config
                        feature.set(&config, on)
                        controller.onConfigChange?(config)
                    }))
            }
        }
    }

    /// Connecting Claude Code is the reason most people install Cove, so it's a button, not a toggle.
    private var agentsCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill").frame(width: 22).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code and Codex").foregroundStyle(Theme.ink)
                Text(agentsDetail).font(.caption).foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if controller.claudeHooks {
                    ConnectedLabel(text: "Claude Code")
                } else {
                    Button("Connect Claude Code") { controller.connectClaude(true) }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .accessibilityIdentifier("welcome.connectClaude")
                }
                switch controller.codex {
                case .connected: ConnectedLabel(text: "Codex")
                case .disconnected, .otherNotifyProgram:
                    Button("Connect Codex") { controller.connectCodex(true) }.buttonStyle(PillButtonStyle())
                case .notInstalled: EmptyView()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
    }

    private var agentsDetail: String {
        if controller.claudeHooks { return "Start a new session and it shows up in the notch" }
        if controller.claudeCodePresent { return "Adds Cove's hooks to Claude Code (with a backup)" }
        return "Install Claude Code, then connect it here or in Settings"
    }

    private var permissions: [Permission] { WelcomeFeature.neededPermissions(model.config) }

    private var allow: some View {
        VStack(spacing: 8) {
            ForEach(permissions) { permission in
                HStack(spacing: 12) {
                    Image(systemName: permission.symbol).frame(width: 22).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title).foregroundStyle(Theme.ink)
                        Text(permission.reason).font(.caption).foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer(minLength: 8)
                    if controller.granted[permission] == true {
                        ConnectedLabel(text: "Allowed")
                    } else {
                        Button("Allow…") { controller.request(permission) }
                            .buttonStyle(PillButtonStyle())
                            .accessibilityIdentifier("welcome.allow.\(permission.rawValue)")
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            }
            if permissions.contains(.fullDiskAccess) {
                Text("Full Disk Access opens System Settings. Switch Cove on there; it applies the next time Cove opens.")
                    .font(.caption).foregroundStyle(Theme.inkTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step != .hello {
                Button("Back") { step = WelcomeStep(rawValue: step.rawValue - 1) ?? .hello }
                    .buttonStyle(PillButtonStyle())
            } else {
                Button("Skip") { finish() }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityIdentifier("welcome.skip")
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(WelcomeStep.allCases, id: \.self) { s in
                    Circle().fill(s == step ? Theme.accent : Theme.surfaceRaised).frame(width: 6, height: 6)
                }
            }
            Spacer()
            Button(step == .allow ? "Done" : "Continue") {
                if let next = WelcomeStep(rawValue: step.rawValue + 1) { step = next } else { finish() }
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("welcome.next")
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }
}

private struct HelloRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
    }
}

private struct PickRow: View {
    let feature: WelcomeFeature
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: feature.symbol).frame(width: 22).foregroundStyle(isOn ? Theme.accent : Theme.inkTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title).foregroundStyle(Theme.ink)
                Text(feature.detail).font(.caption).foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: 8)
            Toggle(feature.title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityIdentifier("welcome.pick.\(feature.id)")
    }
}

private struct ConnectedLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.green)
    }
}

// MARK: - Window

@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private let controller: SettingsController
    private let state = WelcomeState()
    var onFinish: (() -> Void)?

    final class WelcomeState: ObservableObject {
        @Published var step: WelcomeStep = .hello
    }

    private struct Root: View {
        let controller: SettingsController
        @ObservedObject var state: WelcomeState
        let finish: () -> Void

        var body: some View {
            WelcomeView(controller: controller, step: $state.step, finish: finish)
        }
    }

    init(controller: SettingsController) {
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Cove"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: Root(controller: controller, state: state) { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        })
        window.center()
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(step: WelcomeStep = .hello) {
        controller.startRefreshing()
        state.step = step
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        controller.stopRefreshing()
        NSApp.setActivationPolicy(.accessory)
        onFinish?()
    }
}
