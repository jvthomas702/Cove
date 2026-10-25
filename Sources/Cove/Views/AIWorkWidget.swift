import AppKit
import SwiftUI

/// Selected session: companion and observed steps on the left, live detail on the right.
struct AIWorkWidget: View {
    @ObservedObject var model: IslandModel
    private var current: Activity? { model.selectedAIActivity }

    var body: some View {
        Group {
            if let activity = current {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 9) {
                        if model.config.buddy {
                            Buddy(mood: activity.buddyMood, size: 54, badge: activity.agent)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("ai.companion")
                        } else {
                            AgentTile(agent: activity.agent, animating: activity.isLive, size: 36)
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        Text(activity.title).font(Theme.Font.headline).lineLimit(2).help(activity.title)
                        Text(activity.agent.displayName).font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 9) {
                                let steps = Array((model.aiSteps[activity.id] ?? []).suffix(4))
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
                    }.frame(width: 124)
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
                        HStack(spacing: 6) {
                            let cloudSession = model.cloudSessionID(for: activity)
                            Button(cloudSession == nil ? "Open \(activity.agent.displayName)" : "Open on claude.ai") { model.open(activity) }
                                .buttonStyle(PillButtonStyle())
                                .accessibilityIdentifier("ai.open")
                            if cloudSession != nil {
                                Button { model.messageCloudSession(for: activity) } label: { Label("Message", systemImage: "bubble.left") }
                                    .buttonStyle(PillButtonStyle())
                                    .help("Send this cloud session a follow-up from the composer below")
                                    .accessibilityIdentifier("ai.message")
                            }
                            if !activity.detail.isEmpty {
                                IconButton(systemImage: "doc.on.doc", size: 10, hit: 24) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(activity.detail, forType: .string)
                                }
                                .help("Copy this update").accessibilityLabel("Copy update").accessibilityIdentifier("ai.copy")
                            }
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(formatDuration((activity.finishedAt ?? context.date).timeIntervalSince(activity.startedAt)))
                                    .font(Theme.Font.number).foregroundStyle(Theme.inkTertiary)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Theme.background))
                }.id(activity.id).transition(.opacity)
            } else {
                HStack(spacing: 20) {
                    if model.config.buddy { Buddy(mood: .sleepy, size: 54, animating: false) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(emptyTitle).font(Theme.Font.title)
                        Text(model.aiActivities.isEmpty ? "Connect a coding agent or chat app to follow its work here." : "Switch to All to see your other tasks.")
                            .font(Theme.Font.body).foregroundStyle(Theme.inkSecondary)
                        if model.aiActivities.isEmpty {
                            Text(model.desktopAITrackingStatus).font(Theme.Font.caption).foregroundStyle(Theme.inkTertiary)
                        }
                        Button(model.aiActivities.isEmpty ? "Connect AI" : "Show all tasks") {
                            if model.aiActivities.isEmpty { model.openAIConnections() }
                            else { model.aiActivityFilter = .all }
                        }
                            .buttonStyle(PillButtonStyle()).accessibilityIdentifier("ai.emptyAction")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("ai.empty")
            }
        }
        .padding(10)
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

/// One row across the top: a Live/Done/All filter, then a chip per agent. Picking a chip shows its
/// session below. A strip instead of a side column leaves the session the full width.
struct AIWorkOverview: View {
    @ObservedObject var model: IslandModel
    @Namespace private var filterPill
    private var visible: [Activity] { model.filteredAIActivities }
    private var selectedID: String? { model.selectedAIActivity?.id }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(AIActivityFilter.allCases, id: \.self) { filter in
                    Button { model.aiActivityFilter = filter } label: {
                        Text(filter.rawValue).font(Theme.Font.caption)
                            .foregroundStyle(model.aiActivityFilter == filter ? Theme.ink : Theme.inkSecondary)
                            .padding(.horizontal, 8).frame(height: 24)
                            .background {
                                if model.aiActivityFilter == filter {
                                    RoundedRectangle(cornerRadius: Theme.isTerminal ? 3 : 12)
                                        .fill(Theme.surfaceRaised).matchedGeometryEffect(id: "filter", in: filterPill)
                                }
                            }.contentShape(Rectangle())
                    }.buttonStyle(PressableStyle())
                        .accessibilityIdentifier("ai.filter.\(filter.rawValue.lowercased())")
                        .accessibilityAddTraits(model.aiActivityFilter == filter ? .isSelected : [])
                }
            }
            .padding(2).background(RoundedRectangle(cornerRadius: Theme.isTerminal ? 4 : 14).fill(Theme.surface))
            .animation(Theme.snappy, value: model.aiActivityFilter)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, activity in
                        Button { model.selectAIActivity(activity) } label: {
                            HStack(spacing: 6) {
                                AIAgentAvatar(activity: activity, showBuddy: model.config.buddy, size: 20)
                                // The task, not just the agent: three Claude Code sessions shouldn't read alike.
                                Text(activity.title).font(Theme.Font.caption.weight(.semibold))
                                    .foregroundStyle(Theme.ink).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
                                Circle().fill(statusColor(activity)).frame(width: 5, height: 5)
                            }
                            .padding(.leading, 3).padding(.trailing, 9).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: Theme.isTerminal ? 3 : 14)
                                .fill(activity.id == selectedID ? Theme.surfaceRaised : Theme.surface))
                            .overlay { RoundedRectangle(cornerRadius: Theme.isTerminal ? 3 : 14)
                                .strokeBorder(activity.id == selectedID ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1) }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .help("\(activity.agent.displayName) · \(activity.title) · \(activity.phase ?? (activity.isLive ? "Working" : "Finished"))")
                        .accessibilityIdentifier("ai.task.\(activity.id)")
                        .accessibilityAddTraits(activity.id == selectedID ? .isSelected : [])
                        .entrance(index)
                    }
                    if visible.isEmpty {
                        Text(model.aiActivityFilter == .live ? "No agents are working" : model.aiActivityFilter == .finished ? "No recent finished tasks" : "Connect an agent to see it here")
                            .font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
            .scrollIndicators(.never)
            .accessibilityIdentifier("ai.overview")
        }
        .frame(height: 32)
    }

    private func statusColor(_ activity: Activity) -> Color {
        activity.state == .failed ? Palette.red : activity.state == .attention ? Palette.amber : activity.isLive ? Theme.accent : Palette.green
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
