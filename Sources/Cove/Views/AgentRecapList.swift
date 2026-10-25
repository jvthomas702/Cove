import SwiftUI

/// "Today": every Claude Code and Codex run that finished today, newest first.
/// Click a row to jump back to the terminal or app it ran in.
struct AgentRecapList: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SectionTitle(title: "Today", count: model.recap.runs.count)
                Spacer(minLength: 0)
                if model.recap.totalDuration > 0 {
                    Text("\(formatDuration(model.recap.totalDuration)) of agent work")
                        .font(Theme.Font.number).foregroundStyle(Theme.inkTertiary)
                }
            }
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(model.recap.runs.enumerated()), id: \.element.id) { index, run in
                        Button { model.openRecap(run) } label: { row(run).entrance(index) }
                            .buttonStyle(PressableStyle())
                            .help("Open \(run.kind.displayName) · \(run.title)")
                            .accessibilityIdentifier("recap.run.\(run.id)")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.background))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai.recap")
    }

    private func row(_ run: RecapRun) -> some View {
        HStack(spacing: 7) {
            Image(systemName: run.kind.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(run.kind.tint)
                .frame(width: 14)
            Text(run.title).font(Theme.Font.caption).foregroundStyle(Theme.ink).lineLimit(1)
            Text(run.kind.displayName).font(.system(size: 9)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            Spacer(minLength: 6)
            if let files = run.filesChanged, files > 0 {
                Text(files == 1 ? "1 file" : "\(files) files")
                    .font(Theme.Font.number).foregroundStyle(Theme.inkSecondary)
            }
            if let duration = run.duration {
                Text(formatDuration(duration)).font(Theme.Font.number).foregroundStyle(Theme.inkSecondary)
            }
            Text(run.finishedAt.formatted(date: .omitted, time: .shortened))
                .font(Theme.Font.number).foregroundStyle(Theme.inkTertiary)
            Image(systemName: run.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(run.failed ? Palette.red : Palette.green)
                .accessibilityLabel(run.failed ? "Failed" : "Finished")
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
