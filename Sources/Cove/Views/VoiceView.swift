import SwiftUI

/// The island while you talk to Claude: a waveform and your words as they're recognised, then Claude's
/// answer appearing as it's written, with Copy and (when Claude needed permission) Continue in Terminal.
struct VoiceView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var voice: VoiceAssistant

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The notch sits above; content starts below it.
            Color.clear.frame(height: model.notchSize.height)
            header
            if showsReply {
                ScrollView(.vertical) {
                    Text(replyText)
                        .font(.system(size: 12, design: Theme.isTerminal ? .monospaced : .default))
                        .foregroundStyle(isFailure ? Palette.red.opacity(0.9) : Theme.ink)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .animation(Theme.settle, value: voice.reply)
                }
                .scrollIndicators(.never)
                .padding(.top, 8)
                .transition(.materialize)
                .accessibilityIdentifier("voice.reply")
            }
            if voice.phase == .answered { actions.padding(.top, 8).transition(.opacity) }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Theme.ink)
        .animation(Theme.snappy, value: voice.phase)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VoiceIndicator(phase: voice.phase, level: voice.level, buddy: model.config.buddy)
                .frame(width: 34, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(status)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(voice.phase == .listening ? Theme.accent : Theme.inkSecondary)
                    .contentTransition(.opacity)
                Text(voice.transcript.isEmpty ? "Ask Claude anything" : voice.transcript)
                    .font(Theme.Font.headline)
                    .foregroundStyle(voice.transcript.isEmpty ? Theme.inkTertiary : Theme.ink)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .accessibilityIdentifier("voice.transcript")
            }
            Spacer(minLength: 8)
            IconButton(systemImage: "xmark", size: 9, hit: 22) { voice.cancel() }
                .help(voice.phase == .thinking ? "Stop" : "Close")
                .accessibilityLabel(voice.phase == .thinking ? "Stop" : "Close")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if !voice.denied.isEmpty {
                ChipButton(title: "Continue in Terminal", systemImage: "terminal") { voice.continueInTerminal() }
                    .help("Claude needed permission for \(voice.denied.joined(separator: ", ")). Continue there, where it can ask.")
                    .accessibilityIdentifier("voice.terminal")
            }
            ChipButton(title: "Copy", systemImage: "doc.on.doc") { voice.copyReply() }
                .accessibilityIdentifier("voice.copy")
            Spacer(minLength: 0)
            Text("Hold fn to follow up")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    private var isFailure: Bool { if case .failed = voice.phase { return true }; return false }
    private var showsReply: Bool { !voice.reply.isEmpty || isFailure }
    private var replyText: String {
        if case .failed(let message) = voice.phase { return message }
        return voice.reply
    }

    private var status: String {
        switch voice.phase {
        case .listening: return "Listening"
        case .thinking: return voice.activity ?? "Claude is answering"
        case .answered: return "Claude"
        case .failed: return "Couldn't finish"
        case .idle: return ""
        }
    }
}

/// Listening: bars that move with your voice. Thinking: Nori working (or a spinner). Answered: Nori pleased.
private struct VoiceIndicator: View {
    let phase: VoiceAssistant.Phase
    let level: Double
    let buddy: Bool

    var body: some View {
        switch phase {
        case .listening:
            VoiceBars(level: level)
        case .thinking:
            if buddy { Buddy(mood: .working, size: 30) } else { ArcSpinner(color: Theme.accent, size: 16) }
        case .answered:
            if buddy { Buddy(mood: .happy, size: 30) } else {
                Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(AgentKind.claude.tint)
            }
        case .failed:
            if buddy { Buddy(mood: .sad, size: 30) } else {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.red)
            }
        case .idle:
            EmptyView()
        }
    }
}

/// Five bars: their height follows the microphone level, each with its own gentle wobble so the shape
/// keeps moving like Siri's waveform.
private struct VoiceBars: View {
    let level: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: Theme.reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 3.5, height: Self.height(index: index, level: level, time: t))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(Theme.snappy, value: level)
        .accessibilityHidden(true)
    }

    private static let shape: [Double] = [0.45, 0.75, 1.0, 0.75, 0.45]

    private static func height(index: Int, level: Double, time: Double) -> CGFloat {
        let wobble: Double = 0.75 + 0.25 * sin(time * 9 + Double(index) * 1.3)
        let value: Double = 4 + 20 * shape[index] * max(level, 0.08) * wobble
        return CGFloat(value)
    }
}
