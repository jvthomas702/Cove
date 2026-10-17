import SwiftUI

/// The island drops down to show a notification, agent ping, or alert, then tucks back in.
/// A hairline along the bottom shows how long it will stay.
struct BannerView: View {
    @ObservedObject var model: IslandModel
    let banner: Banner
    @State private var reply = ""
    @State private var replyError: String?
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchSize.height)
                .contentShape(Rectangle())
                .onTapGesture { model.tapBanner(banner) }
            HStack(alignment: .center, spacing: Theme.Space.m) {
                bannerIcon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let source = sourceName {
                            Text(source)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.inkTertiary)
                                .lineLimit(1)
                                .layoutPriority(-1)
                        }
                        Spacer(minLength: 4)
                        if banner.sticky {
                            Button {
                                model.dismissBanner()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.inkTertiary)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(Theme.surface))
                            }
                            .buttonStyle(PressableStyle())
                        } else {
                            Text("now")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    Text(banner.title)
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let replyError {
                        Text(replyError)
                            .font(Theme.Font.body)
                            .foregroundStyle(Palette.red)
                            .lineLimit(1)
                            .accessibilityIdentifier("banner.replyError")
                    } else if !banner.body.isEmpty {
                        Text(banner.body)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.tapBanner(banner) }

            if let target = model.replyTarget(for: banner) {
                replyField(target)
            }

            if !banner.sticky && !model.bannerHeld {
                CountdownHairline(duration: banner.duration ?? model.config.bannerSeconds, tint: banner.style.tint)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 7)
            }
        }
    }

    /// "Reply…" continues the finished session in Terminal (`claude --resume` / `codex resume`).
    private func replyField(_ target: ResumeTarget) -> some View {
        HStack(spacing: Theme.Space.s) {
            TextField("Reply…", text: $reply)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.ink)
                .focused($replyFocused)
                .onSubmit(sendReply)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Theme.surface))
                .help("Continues this \(target.agent.rawValue) session in Terminal")
                .accessibilityIdentifier("banner.reply")
            Button(action: sendReply) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.accent))
            }
            .buttonStyle(PressableStyle())
            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            .help("Send")
            .accessibilityLabel("Send reply")
            .accessibilityIdentifier("banner.replySend")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.bottom, banner.sticky || model.bannerHeld ? 10 : 4)
        .onChange(of: replyFocused) { _, _ in engagementChanged() }
        .onChange(of: reply) { _, _ in replyError = nil; engagementChanged() }
    }

    private func engagementChanged() {
        model.setBannerReplyEngaged(replyFocused || !reply.isEmpty)
    }

    private func sendReply() {
        let text = reply
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let error = model.sendBannerReply(text, for: banner) {
            replyError = error
        } else {
            reply = ""
        }
    }

    /// Screenshots get a bigger thumbnail you can drag straight out of the notch.
    @ViewBuilder
    private var bannerIcon: some View {
        if case .file(let url) = banner.icon {
            FileThumbnail(url: url, size: 48)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .help("Drag the screenshot anywhere")
                .transition(.scale(scale: 1.6).combined(with: .opacity))
        } else {
            BannerIconView(icon: banner.icon, size: 36)
                .background {
                    if case .buddy(.happy, _) = banner.icon { ConfettiBurst() }
                }
        }
    }

    /// The small line above the title: the app's name for mirrored notifications, the event type otherwise.
    private var sourceName: String? {
        if let source = banner.source { return source }
        switch banner.icon {
        case .app(let bundleID): return AppIcons.name(for: bundleID)
        case .file: return "Shelf"
        case .symbol, .buddy:
            switch banner.style {
            case .success: return banner.activityID == nil ? "Done" : "Finished"
            case .attention: return "Needs you"
            case .failure: return "Failed"
            case .info: return nil
            }
        }
    }
}

/// Shrinks from full width to nothing over the banner's lifetime.
private struct CountdownHairline: View {
    let duration: TimeInterval
    let tint: Color
    @State private var remaining: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(tint.opacity(0.5))
                .frame(width: geo.size.width * remaining)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: 2)
        .onAppear {
            withAnimation(.linear(duration: duration)) { remaining = 0 }
        }
    }
}
