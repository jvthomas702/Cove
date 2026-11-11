import SwiftUI

struct AIUsageView: View {
    @ObservedObject var model: IslandModel
    @State private var showsLimits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Sessions seen today").font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Button("Account limits") { showsLimits.toggle() }
                    .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("ai.limits.open")
                    .popover(isPresented: $showsLimits, arrowEdge: .bottom) {
                        AccountLimitsView(limits: model.accountLimits, port: model.config.port)
                            .onAppear { model.setMenuTracking(true) }
                            .onDisappear { model.setMenuTracking(false) }
                    }
                if model.aiUsageSourceFilter != nil {
                    Button("Show all") { model.aiUsageSourceFilter = nil }
                        .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("ai.usage.all")
                }
            }
            HStack(spacing: 6) {
                ForEach(AIUsageSource.allCases, id: \.self) { source in
                    sourceCard(source)
                }
            }
            Text("Reported tokens cover whole sessions. Some apps do not report tokens.")
                .font(.system(size: 9)).foregroundStyle(Theme.inkTertiary)
        }
        .frame(height: IslandModel.usageHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai.usage")
    }

    private func sourceCard(_ source: AIUsageSource) -> some View {
        let summary = model.aiUsage.summary(for: source)
        let live = model.aiActivities.filter { $0.usageSource == source && $0.isLive }.count
        let selected = model.aiUsageSourceFilter == source
        return Button {
            model.aiUsageSourceFilter = selected ? nil : source
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: source.symbol)
                    Text(source.title).fontWeight(.semibold)
                    Spacer(minLength: 0)
                    if live > 0 { Text("\(live) live").foregroundStyle(Theme.accent) }
                }.font(Theme.Font.caption)
                Text("\(summary.sessions) \(summary.sessions == 1 ? "session" : "sessions") · \(summary.tokenLabel)")
                    .font(.system(size: 9)).foregroundStyle(Theme.inkSecondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Theme.surface))
            .overlay { RoundedRectangle(cornerRadius: Theme.Radius.row)
                .strokeBorder(selected ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(Theme.ink)
        .accessibilityIdentifier("ai.usage.\(source.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(summary.sessions) \(source.title.lowercased()) sessions observed today. \(summary.reportingSessions) report tokens. "
              + (summary.tokens.map { "\($0.input.formatted()) input, \($0.output.formatted()) output. " } ?? "")
              + "Click to filter recent tasks.")
    }
}
