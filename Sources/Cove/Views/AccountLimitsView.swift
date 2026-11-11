import AppKit
import SwiftUI

struct AccountLimitsView: View {
    @ObservedObject var limits: AccountLimits
    var port: UInt16
    @State private var claudeConnected = ClaudeUsageSetup.isInstalled
    @State private var setupError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Account limits").font(Theme.Font.headline)
                Spacer()
                Button(limits.refreshing ? "Refreshing…" : "Refresh Codex") { Task { await limits.refresh() } }
                    .buttonStyle(PillButtonStyle()).disabled(limits.refreshing)
                    .accessibilityIdentifier("ai.limits.refresh")
            }
            Text("Provider-reported allowances across your account. Activity cards track where sessions run.")
                .font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    provider("Codex", windows: limits.codex, status: limits.codexStatus, updated: limits.codexUpdatedAt)
                    Divider()
                    provider("Claude", windows: limits.claude, status: limits.claudeStatus, updated: limits.claudeUpdatedAt)
                    Button(claudeConnected ? "Disconnect Claude limits" : "Connect Claude limits") {
                        do {
                            try ClaudeUsageSetup.set(installed: !claudeConnected, port: port)
                            claudeConnected = ClaudeUsageSetup.isInstalled
                            setupError = nil
                        } catch { setupError = error.localizedDescription }
                    }.buttonStyle(PillButtonStyle()).accessibilityIdentifier("ai.limits.claudeConnect")
                    Text("Claude updates after responses in Claude Code. Connecting preserves your current status line; disconnecting restores it.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.inkTertiary)
                    if let setupError { Text(setupError).font(Theme.Font.caption).foregroundStyle(Palette.red) }
                    Link("Open Claude usage", destination: URL(string: "https://claude.ai/settings/usage")!)
                        .font(Theme.Font.caption)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16).frame(width: 380, height: 380)
        .foregroundStyle(Theme.ink).background(Theme.background)
        .environment(\.colorScheme, .dark)
        .task { await limits.refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai.limits")
    }

    private func provider(_ title: String, windows: [QuotaWindow], status: String, updated: Date?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(Theme.Font.headline)
                Spacer()
                if let updated {
                    Text(updated, style: .relative).font(Theme.Font.caption).foregroundStyle(Theme.inkTertiary)
                        .help("Last reported \(updated.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            if windows.isEmpty { Text(status).font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary) }
            ForEach(windows) { window in
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(window.title)
                            Spacer()
                            Text(window.expired(at: context.date) ? "Awaiting update" : "\(Int(window.remainingPercent.rounded(.down)))% remaining")
                        }.font(Theme.Font.caption)
                        if !window.expired(at: context.date) {
                            ProgressView(value: min(window.remainingPercent, 100), total: 100).tint(window.remainingPercent < 15 ? Palette.amber : Theme.accent)
                        }
                        if let reset = window.resetsAt {
                            Text(window.expired(at: context.date) ? "Reset time passed; refresh for current limits." : "Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 9)).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                }.accessibilityIdentifier("ai.limits.\(title.lowercased()).\(window.id)")
            }
        }
    }
}
