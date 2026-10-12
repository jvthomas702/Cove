import SwiftUI

/// Claude Code is asking permission. Shows exactly what it wants to do and answers the hook directly.
struct ApprovalView: View {
    @ObservedObject var model: IslandModel
    let request: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: model.notchSize.height - 6)

            HStack(spacing: 10) {
                AgentGlyph(agent: .claude, animating: true, size: 15)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Palette.claude.opacity(0.16)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude wants to \(request.action)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, request.expiresAt.timeIntervalSince(context.date))
                    let total = max(request.expiresAt.timeIntervalSince(request.createdAt), 1)
                    ZStack {
                        ProgressRing(progress: remaining / total, color: Palette.amber, size: 22)
                        Text("\(Int(remaining))")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }

            PreviewBox(preview: request.preview)

            HStack(spacing: 8) {
                ApprovalButton(title: "Deny", systemImage: "xmark", style: .destructive) {
                    model.resolveApproval(request.id, .deny)
                }
                ApprovalButton(title: "Terminal", systemImage: "terminal", style: .plain) {
                    model.answerInTerminal(request.id)
                }
                Spacer(minLength: 4)
                if request.canAlwaysAllow {
                    ApprovalButton(title: "Always allow", systemImage: "checkmark.seal", style: .plain) {
                        model.resolveApproval(request.id, .allowAlways)
                    }
                }
                ApprovalButton(title: "Allow", systemImage: "checkmark", style: .primary) {
                    model.resolveApproval(request.id, .allow)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
    }

    private var subtitle: String {
        var parts = [request.project, request.tool]
        let waiting = model.approvals.count - 1
        if waiting > 0 { parts.append("+\(waiting) more waiting") }
        return parts.joined(separator: " · ")
    }
}

private struct PreviewBox: View {
    let preview: ApprovalPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(preview.lines) { line in
                Text(line.text)
                    .font(.system(size: 11, design: line.style == .meta ? .default : .monospaced))
                    .foregroundStyle(color(for: line.style))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(background(for: line.style))
            }
            if preview.lines.isEmpty {
                Text("No details provided")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func color(for style: ApprovalPreview.Style) -> Color {
        switch style {
        case .plain, .code: return .white.opacity(0.9)
        case .added: return Palette.green
        case .removed: return Palette.red
        case .meta: return .white.opacity(0.5)
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
    enum Style { case primary, destructive, plain }
    let title: String
    let systemImage: String
    let style: Style
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(fill.opacity(hovering ? 1 : 0.85)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch style {
        case .primary: return .black
        case .destructive: return Palette.red
        case .plain: return .white
        }
    }

    private var fill: Color {
        switch style {
        case .primary: return Palette.green
        case .destructive: return Palette.red.opacity(0.18)
        case .plain: return Color.white.opacity(0.12)
        }
    }
}
