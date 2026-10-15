import SwiftUI

struct AIWorkWidget: View {
    @ObservedObject var model: IslandModel

    private var current: Activity? {
        model.aiActivities.first(where: { $0.id == model.selectedAIActivityID }) ?? model.aiActivities.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "AI work", count: model.aiActivities.filter(\.isLive).count)
                Spacer()
                if model.aiActivities.count > 1 {
                    Menu {
                        ForEach(model.aiActivities) { activity in
                            Button("\(activity.agent.displayName) · \(activity.title)") { model.selectedAIActivityID = activity.id }
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
                .fill(Theme.surface)
        }
    }
}


struct AIWorkOverview: View {
    @ObservedObject var model: IslandModel
    @State private var filter = "All"
    private var visible: [Activity] {
        model.aiActivities.filter { filter == "All" || (filter == "Working" ? $0.isLive : !$0.isLive) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(title: "AI tasks", count: model.aiActivities.count)
                Spacer()
                Picker("AI tasks filter", selection: $filter) {
                    Text("All").tag("All"); Text("Working").tag("Working"); Text("Finished").tag("Finished")
                }.labelsHidden().pickerStyle(.menu).frame(width: 90)
                    .accessibilityIdentifier("ai.filter")
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(visible) { activity in
                        VStack(alignment: .leading, spacing: 4) {
                            Button { model.selectedAIActivityID = activity.id } label: {
                                HStack(alignment: .top, spacing: 7) {
                                    AgentTile(agent: activity.agent, animating: activity.isLive, size: 23)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(activity.title).font(Theme.Font.headline).lineLimit(1)
                                        Text("\(activity.agent.displayName) · \(activity.originLabel)").font(.system(size: 9)).foregroundStyle(Theme.inkTertiary)
                                        Text(activity.phase ?? (activity.isLive ? "Working" : activity.state == .failed ? "Failed" : "Finished"))
                                            .font(Theme.Font.caption).foregroundStyle(activity.state == .failed ? Palette.red : activity.agent.tint)
                                        Text(activity.detail).font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        Text(formatDuration((activity.finishedAt ?? context.date).timeIntervalSince(activity.startedAt)))
                                            .font(Theme.Font.number).foregroundStyle(Theme.inkTertiary)
                                    }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("ai.task.\(activity.id)")
                            HStack {
                                Spacer()
                                Button("Return to \(activity.agent.displayName)") { model.open(activity) }
                                    .font(Theme.Font.caption).foregroundStyle(activity.agent.tint).buttonStyle(.plain)
                                    .accessibilityIdentifier("ai.open.\(activity.id)")
                            }
                        }.padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(activity.id == model.selectedAIActivityID ? Theme.surfaceRaised : Theme.surface))
                    }
                }
            }.accessibilityIdentifier("ai.overview")
            if visible.isEmpty {
                Text(filter == "Working" ? "No AI tasks are running" : filter == "Finished" ? "No recent finished tasks" : "Your connected AI tasks appear here")
                    .font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
            }
        }
    }
}
