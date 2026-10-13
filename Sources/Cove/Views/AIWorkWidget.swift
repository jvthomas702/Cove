import SwiftUI

struct AIWorkWidget: View {
    @ObservedObject var model: IslandModel
    @State private var selectedID: String?

    private var current: Activity? {
        model.aiActivities.first(where: { $0.id == selectedID }) ?? model.aiActivities.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "AI work", count: model.aiActivities.filter(\.isLive).count)
                Spacer()
                if model.aiActivities.count > 1 {
                    Menu {
                        ForEach(model.aiActivities) { activity in
                            Button("\(activity.agent.displayName) · \(activity.title)") { selectedID = activity.id }
                        }
                    } label: { Image(systemName: "list.bullet") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose the activity shown in this widget")
                }
            }
            if let activity = current {
                HStack(spacing: 8) {
                    AgentTile(agent: activity.agent, animating: activity.isLive, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.agent.displayName).font(Theme.Font.headline)
                        Text(activity.originLabel).font(Theme.Font.caption).foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer()
                    if activity.state == .running { ArcSpinner(color: activity.agent.tint, size: 13) }
                    else if activity.state == .failed { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.red) }
                    else if activity.state == .attention { Image(systemName: "hand.raised.fill").foregroundStyle(Palette.amber) }
                    else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green) }
                }
                Text(activity.title).font(Theme.Font.headline).lineLimit(1)
                Text(activity.phase ?? (activity.isLive ? "Working" : "Finished"))
                    .font(Theme.Font.caption).foregroundStyle(activity.agent.tint)
                Text(activity.detail).font(Theme.Font.body).foregroundStyle(Theme.inkSecondary).lineLimit(3)
                Spacer(minLength: 0)
                HStack {
                    Button("Open \(activity.agent.displayName)") { model.open(activity) }
                        .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(activity.agent.tint)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(formatDuration((activity.finishedAt ?? context.date).timeIntervalSince(activity.startedAt)))
                            .font(Theme.Font.number).foregroundStyle(Theme.inkTertiary)
                    }
                }
            } else {
                Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(Palette.blue)
                Text("Ready for your next task").font(Theme.Font.headline)
                Text("ChatGPT app, browser chats, Claude Code and Codex activity appear here.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                Spacer(minLength: 0)
                Text(model.desktopAIStatus).font(Theme.Font.caption).foregroundStyle(Theme.inkTertiary)
                Button("Set up connections") { model.openSettings?(.connections) }
                    .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Palette.blue)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(LinearGradient(colors: [(current?.agent.tint ?? Palette.blue).opacity(0.18), Theme.surface],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}
