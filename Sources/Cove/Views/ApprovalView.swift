import SwiftUI

/// Claude Code is asking permission. Shows exactly what it wants to do and answers the hook directly.
struct ApprovalView: View {
    @ObservedObject var model: IslandModel
    let request: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Color.clear.frame(height: model.notchSize.height - 4)

            HStack(spacing: Theme.Space.m) {
                if model.config.buddy {
                    Buddy(mood: .alert, size: 38, badge: .claude)
                } else {
                    AgentTile(agent: .claude, animating: true, size: 34)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow Claude to \(request.action)?")
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(request.project)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                        Text(request.tool)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.inkSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Theme.surfaceRaised))
                        if waiting > 0 {
                            Text("\(waiting) more waiting")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Palette.amber)
                        }
                    }
                }
                Spacer(minLength: Theme.Space.s)
                Countdown(request: request)
            }

            PreviewBox(preview: request.preview)

            HStack(spacing: Theme.Space.s) {
                ApprovalButton(title: "Deny", systemImage: "xmark", style: .destructive) {
                    model.resolveApproval(request.id, .deny)
                }
                .help(shortcutHint("N"))
                ApprovalButton(title: "Answer in terminal", systemImage: "terminal", style: .quiet) {
                    model.answerInTerminal(request.id)
                }
                .help(shortcutHint("T"))
                Spacer(minLength: Theme.Space.xs)
                if request.canAlwaysAllow {
                    ApprovalButton(title: "Always allow", systemImage: nil, style: .secondary) {
                        model.resolveApproval(request.id, .allowAlways)
                    }
                    .help(shortcutHint("A"))
                }
                ApprovalButton(title: "Allow", systemImage: "checkmark", style: .primary) {
                    model.resolveApproval(request.id, .allow)
                }
                .help(shortcutHint("Y"))
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var waiting: Int { max(model.approvals.count - 1, 0) }

    private func shortcutHint(_ key: String) -> String { model.config.shortcuts ? "⌃⌥\(key)" : "" }
}

/// Seconds left before the prompt goes back to the terminal.
private struct Countdown: View {
    let request: ApprovalRequest

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, request.expiresAt.timeIntervalSince(context.date))
            let total = max(request.expiresAt.timeIntervalSince(request.createdAt), 1)
            ZStack {
                ProgressRing(progress: remaining / total, color: remaining < 15 ? Palette.red : Palette.amber, size: 26, lineWidth: 2.5)
                Text("\(Int(remaining.rounded(.up)))")
                    .font(.system(size: 9, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
            }
            .help("Goes back to the terminal when this runs out")
        }
    }
}

private struct PreviewBox: View {
    let preview: ApprovalPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(preview.lines) { line in
                Text(line.text)
                    .font(line.style == .meta ? Theme.Font.caption : Theme.Font.code)
                    .foregroundStyle(color(for: line.style))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(background(for: line.style))
                    )
                    .padding(.bottom, line.style == .meta ? 3 : 0)
            }
            if preview.lines.isEmpty {
                Text("No details were provided for this request")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card - 4, style: .continuous).fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card - 4, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card - 4, style: .continuous))
    }

    private func color(for style: ApprovalPreview.Style) -> Color {
        switch style {
        case .plain, .code: return Theme.ink
        case .added: return Palette.green
        case .removed: return Palette.red
        case .meta: return Theme.inkSecondary
        }
    }

    private func background(for style: ApprovalPreview.Style) -> Color {
        switch style {
        case .added: return Palette.green.opacity(0.1)
        case .removed: return Palette.red.opacity(0.1)
        default: return .clear
        }
    }
}

private struct ApprovalButton: View {
    enum Style { case primary, secondary, destructive, quiet }
    let title: String
    let systemImage: String?
    let style: Style
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10.5, weight: .bold)) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, style == .quiet ? 8 : 14)
            .frame(height: 30)
            .background(Capsule().fill(fill))
            .brightness(hovering && style == .primary ? 0.06 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch style {
        case .primary: return .black
        case .secondary: return Theme.ink
        case .destructive: return Palette.red
        case .quiet: return hovering ? Theme.ink : Theme.inkSecondary
        }
    }

    private var fill: Color {
        switch style {
        case .primary: return Palette.green
        case .secondary: return hovering ? Color.white.opacity(0.16) : Theme.surfaceRaised
        case .destructive: return Palette.red.opacity(hovering ? 0.24 : 0.16)
        case .quiet: return hovering ? Theme.surface : .clear
        }
    }
}
