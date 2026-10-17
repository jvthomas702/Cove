import SwiftUI

/// Selected session: companion and observed steps on the left, live detail on the right.
struct AIWorkWidget: View {
    @ObservedObject var model: IslandModel
    private var current: Activity? { model.selectedAIActivity }

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
                        if let tokens = activity.tokens {
                            Text(tokens.short).font(Theme.Font.number).foregroundStyle(Theme.inkTertiary)
                                .help("\(tokens.input.formatted()) in, \(tokens.output.formatted()) out")
                                .accessibilityIdentifier("ai.tokens")
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
                                .buttonStyle(PillButtonStyle())
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
                }.id(activity.id).transition(.opacity)
            } else {
                HStack(spacing: 20) {
                    if model.config.buddy { Buddy(mood: .sleepy, size: 92, animating: false) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(emptyTitle).font(Theme.Font.title)
                        Text(model.aiActivities.isEmpty ? "Connect a coding agent or chat app to follow its work here." : "Switch to All to see your other tasks.")
                            .font(Theme.Font.body).foregroundStyle(Theme.inkSecondary)
                        if model.aiActivities.isEmpty {
                            Text(model.desktopAITrackingStatus).font(Theme.Font.caption).foregroundStyle(Theme.inkTertiary)
                        }
                        Button(model.aiActivities.isEmpty ? "Connect AI →" : "Show all tasks →") {
                            if model.aiActivities.isEmpty { model.openAIConnections() }
                            else { model.aiActivityFilter = .all }
                        }
                            .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                            .frame(height: 30).contentShape(Rectangle()).accessibilityIdentifier("ai.emptyAction")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("ai.empty")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
        .animation(.easeOut(duration: Theme.reduceMotion ? 0.10 : 0.16), value: current?.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai.session")
    }

    private func statusColor(_ activity: Activity) -> Color {
        activity.state == .failed ? Palette.red : activity.state == .attention ? Palette.amber : Theme.accent
    }

    private var emptyTitle: String {
        if model.aiActivities.isEmpty { return "Ready for your next task" }
        return model.aiActivityFilter == .live ? "Nothing working right now" : "No finished tasks yet"
    }
}

/// Agent pills choose the session shown beside Nori; row avatars remain still.
struct AIWorkOverview: View {
    @ObservedObject var model: IslandModel
    @Namespace private var filterPill
    private var visible: [Activity] { model.filteredAIActivities }
    private var selectedID: String? { model.selectedAIActivity?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionTitle(title: "Agents", count: model.aiActivities.count)
            HStack(spacing: 2) {
                ForEach(AIActivityFilter.allCases, id: \.self) { filter in
                    Button { model.aiActivityFilter = filter } label: {
                        Text(filter.rawValue).font(Theme.Font.caption)
                            .foregroundStyle(model.aiActivityFilter == filter ? Theme.ink : Theme.inkSecondary)
                            .frame(maxWidth: .infinity).frame(height: 28)
                            .background {
                                if model.aiActivityFilter == filter {
                                    Capsule().fill(Theme.surfaceRaised).matchedGeometryEffect(id: "filter", in: filterPill)
                                }
                            }.contentShape(Capsule())
                    }.buttonStyle(PressableStyle())
                        .accessibilityIdentifier("ai.filter.\(filter.rawValue.lowercased())")
                        .accessibilityAddTraits(model.aiActivityFilter == filter ? .isSelected : [])
                }
            }
            .padding(2).background(Capsule().fill(Theme.background))
            .animation(Theme.snappy, value: model.aiActivityFilter)
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(visible) { activity in
                        Button { model.selectAIActivity(activity) } label: {
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
                        .accessibilityAddTraits(activity.id == selectedID ? .isSelected : [])
                    }
                }
            }.accessibilityIdentifier("ai.overview")
            if visible.isEmpty {
                Text(model.aiActivityFilter == .live ? "No agents are working" : model.aiActivityFilter == .finished ? "No recent finished tasks" : "Connect an agent to see it here")
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
