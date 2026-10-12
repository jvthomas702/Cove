import AppKit
import SwiftUI

/// Hover the notch to open this: media, focus timer, agent activity, recent notifications, and the file shelf.
struct ExpandedView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch model.tab {
                case .home: HomePane(model: model)
                case .shelf: ShelfPane(model: model)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                tabButton(.home, symbol: "house.fill")
                tabButton(.shelf, symbol: model.shelf.isEmpty ? "tray.fill" : "tray.full.fill")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: model.notchSize.width)

            HStack(spacing: 8) {
                if let battery = model.battery {
                    HStack(spacing: 4) {
                        Text("\(battery.percent)%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Image(systemName: battery.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(battery.percent <= 20 && !battery.pluggedIn ? Palette.red : Color.white)
                    }
                    .foregroundStyle(.white.opacity(0.75))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: model.notchSize.height)
    }

    private func tabButton(_ tab: IslandModel.Tab, symbol: String) -> some View {
        IconButton(systemImage: symbol, size: 12) { model.tab = tab }
            .foregroundStyle(model.tab == tab ? Color.white : Color.white.opacity(0.4))
    }
}

// MARK: - Home

struct HomePane: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 10) {
                MediaCard(model: model)
                FocusCard(model: model)
            }
            .frame(width: 236)

            ActivityList(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct MediaCard: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 10) {
            if let np = model.nowPlaying {
                ArtworkView(nowPlaying: np, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(np.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(np.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        IconButton(systemImage: "backward.fill", size: 12) { model.media("previous track") }
                        IconButton(systemImage: np.isPlaying ? "pause.fill" : "play.fill", size: 15) { model.media("playpause") }
                        IconButton(systemImage: "forward.fill", size: 12) { model.media("next track") }
                    }
                    .padding(.leading, -6)
                }
                Spacer(minLength: 0)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing playing").font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text("Music or Spotify shows up here").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(height: 76)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.card))
    }
}

struct FocusCard: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 10) {
            if let end = model.focusEnd {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, end.timeIntervalSince(context.date))
                    let total = max(model.focusTotal, 1)
                    ProgressRing(progress: 1 - remaining / total, color: Palette.amber, size: 30)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Focus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(timerInterval: Date()...max(end, Date()), countsDown: true)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                ChipButton(title: "Stop", systemImage: "stop.fill", tint: Palette.red) { model.stopFocus() }
            } else {
                Image(systemName: "timer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.amber)
                Text("Focus")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
                ForEach(model.config.focusMinutes.prefix(3), id: \.self) { minutes in
                    ChipButton(title: "\(minutes)m") { model.startFocus(minutes: minutes) }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.card))
    }
}

// MARK: - Activity

struct ActivityList: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ACTIVITY")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text(model.serverStatus)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
            if model.activities.isEmpty && model.history.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(Palette.claude)
                    Text("Agents, long commands and notifications show up here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(model.activities) { activity in
                            ActivityRow(activity: activity) { model.open(activity) }
                        }
                        ForEach(model.history.prefix(8)) { banner in
                            HistoryRow(banner: banner) { model.tapBanner(banner) }
                        }
                    }
                }
            }
        }
    }
}

struct ActivityRow: View {
    let activity: Activity
    var onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            AgentGlyph(agent: activity.agent, animating: activity.state == .running, size: 13)
                .frame(width: 26, height: 26)
                .background(Circle().fill(activity.agent.tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(activity.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    if !activity.seen {
                        Circle().fill(Palette.green).frame(width: 6, height: 6)
                    }
                    Spacer(minLength: 4)
                    timeLabel
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.45))
                }
                Text(activity.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                if let progress = activity.progress, activity.state == .running {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule().fill(activity.agent.tint).frame(width: geo.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 3)
                }
            }
            stateBadge
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hovering ? 0.11 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private var timeLabel: some View {
        if activity.isLive {
            Text(activity.startedAt, style: .timer)
        } else if let finished = activity.finishedAt {
            Text(finished, style: .relative)
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch activity.state {
        case .running:
            if let progress = activity.progress {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(activity.agent.tint)
            } else {
                ArcSpinner(color: activity.agent.tint, size: 12)
            }
        case .attention:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.amber)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.red)
        }
    }
}

struct HistoryRow: View {
    let banner: Banner
    var onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            BannerIconView(icon: banner.icon)
                .frame(width: 22, height: 22)
                .padding(2)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(banner.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(banner.date, style: .relative)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
                if !banner.body.isEmpty {
                    Text(banner.body)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hovering ? 0.09 : 0.03)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Shelf

struct ShelfPane: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if model.shelf.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Palette.blue)
                Text("Drop files on the notch to park them here")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("Drag them back out into any app when you need them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("SHELF · \(model.shelf.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    ChipButton(title: "Clear", systemImage: "trash") { model.clearShelf() }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.shelf, id: \.self) { url in
                            ShelfItem(url: url, model: model)
                        }
                    }
                }
            }
        }
    }
}

struct ShelfItem: View {
    let url: URL
    @ObservedObject var model: IslandModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 52)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 78)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0)))
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Remove from Shelf") { model.removeFromShelf(url) }
        }
    }
}
