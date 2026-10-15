import SwiftUI

/// Selected session: companion and observed steps on the left, live detail on the right.
struct AIWorkWidget: View {
    @ObservedObject var model: IslandModel
    private var current: Activity? {
        model.aiActivities.first(where: { $0.id == model.selectedAIActivityID }) ?? model.aiActivities.first
    }

    var body: some View {
        Group {
            if let activity = current {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 9) {
                        if model.config.buddy {
                            Buddy(mood: activity.buddyMood, size: 92, badge: activity.agent)
                                .frame(maxWidth: .infinity).padding(.top, 6)
                                .accessibilityIdentifier("ai.companion")
                        } else {
                            AgentTile(agent: activity.agent, animating: activity.isLive, size: 44)
                                .frame(maxWidth: .infinity).padding(.vertical, 18)
                        }
                        Text(activity.title).font(Theme.Font.title).lineLimit(2).help(activity.title)
                        Text(activity.agent.displayName).font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 9) {
                                let steps = Array((model.aiSteps[activity.id] ?? []).suffix(5))
                                ForEach(steps) { step in
                                    HStack(spacing: 7) {
                                        Image(systemName: step.state == .done ? "checkmark.circle.fill" : step.state == .failed ? "xmark.circle.fill" : step.state == .attention ? "hand.raised.fill" : "circle.fill")
                                            .font(.system(size: step.state == .running ? 6 : 11))
                                            .foregroundStyle(step.state == .failed ? Palette.red : step.state == .attention ? Palette.amber : step.id == steps.last?.id ? Theme.accent : Theme.inkTertiary)
                                        Text(step.phase).font(Theme.Font.caption).lineLimit(1)
                                            .foregroundStyle(step.id == steps.last?.id ? Theme.ink : Theme.inkSecondary)
                                    }.help(step.detail)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityIdentifier("ai.steps")
                    }.frame(width: 140)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Circle().fill(statusColor(activity)).frame(width: 6, height: 6)
                            Text(activity.phase ?? (activity.isLive ? "Working" : "Finished"))
                                .font(Theme.Font.headline).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(activity.originLabel).font(.system(size: 9)).foregroundStyle(Theme.inkTertiary)
                        }
                        Divider().overlay(Theme.hairline)
                        ScrollView {
                            Text(activity.detail.isEmpty ? "Waiting for the next activity update" : activity.detail)
                                .font(activity.agent == .claude || activity.agent == .codex ? Theme.Font.code : Theme.Font.body)
                                .foregroundStyle(Theme.inkSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }.accessibilityIdentifier("ai.detail")
                        HStack {
                            Button("Open \(activity.agent.displayName)") { model.open(activity) }
                                .font(Theme.Font.caption).buttonStyle(.plain).foregroundStyle(Theme.accent)
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(formatDuration((activity.finishedAt ?? context.date).timeIntervalSince(activity.startedAt)))
                                    .font(Theme.Font.number).foregroundStyle(Theme.inkTertiary)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.background))
                }
            } else {
                HStack(spacing: 20) {
                    if model.config.buddy { Buddy(mood: .sleepy, size: 92, animating: false) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ready for your next task").font(Theme.Font.title)
                        Text("Claude Code, Codex and connected AI chats appear here.")
                            .font(Theme.Font.body).foregroundStyle(Theme.inkSecondary)
                        Text(model.desktopAIStatus).font(Theme.Font.caption).foregroundStyle(Theme.inkTertiary)
                        Button("Set up connections") { model.openSettings?(.connections) }
                            .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
        .accessibilityIdentifier("ai.session")
    }

    private func statusColor(_ activity: Activity) -> Color {
        activity.state == .failed ? Palette.red : activity.state == .attention ? Palette.amber : Theme.accent
    }
}

/// Agent pills choose the session shown beside Pip; row avatars remain still.
struct AIWorkOverview: View {
    @ObservedObject var model: IslandModel
    @State private var filter = "All"
    private var visible: [Activity] {
        model.aiActivities.filter { filter == "All" || (filter == "Working" ? $0.isLive : !$0.isLive) }
    }
    private var selectedID: String? { model.selectedAIActivityID ?? model.aiActivities.first?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionTitle(title: "Agents", count: model.aiActivities.count)
                Spacer()
                Picker("AI tasks filter", selection: $filter) {
                    Text("All").tag("All"); Text("Working").tag("Working"); Text("Finished").tag("Finished")
                }.labelsHidden().pickerStyle(.menu).frame(width: 90)
                    .accessibilityIdentifier("ai.filter")
            }
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(visible) { activity in
                        Button { model.selectedAIActivityID = activity.id } label: {
                            HStack(spacing: 9) {
                                AIAgentAvatar(activity: activity, showBuddy: model.config.buddy, size: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(activity.agent.displayName).font(Theme.Font.headline).foregroundStyle(Theme.ink)
                                    Text(activity.title).font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                                    Text(activity.phase ?? (activity.isLive ? "Working" : "Finished"))
                                        .font(.system(size: 9)).foregroundStyle(activity.state == .failed ? Palette.red : activity.state == .attention ? Palette.amber : Theme.accent).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: activity.id == selectedID ? "chevron.right" : "circle")
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 13).fill(activity.id == selectedID ? Theme.surfaceRaised : Theme.background))
                            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(activity.id == selectedID ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: 1) }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityIdentifier("ai.task.\(activity.id)")
                    }
                }
            }.accessibilityIdentifier("ai.overview")
            if visible.isEmpty {
                Text(filter == "Working" ? "No agents are working" : filter == "Finished" ? "No recent finished tasks" : "Connect an agent to see it here")
                    .font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
    }
}

struct AIAgentAvatar: View {
    let activity: Activity
    var showBuddy = true
    var size: CGFloat = 30
    var body: some View {
        Group {
            if showBuddy { Buddy(mood: activity.buddyMood, size: size * 0.88, animating: false) }
            else { Image(systemName: activity.agent.symbol).font(.system(size: size * 0.4)).foregroundStyle(.white) }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.30).fill(activity.agent.tint))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(activity.agent.displayName), \(activity.phase ?? "AI activity")")
    }
}
