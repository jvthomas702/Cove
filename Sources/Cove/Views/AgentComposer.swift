import SwiftUI

struct AgentComposer: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var launcher: AgentLauncher
    @FocusState private var focused: Bool

    init(model: IslandModel) {
        self.model = model
        self.launcher = model.agentLauncher
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Picker("Agent", selection: $launcher.agent) {
                    ForEach(LaunchAgent.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 120).accessibilityIdentifier("agent.choice")
                Button {
                    model.openByClick(); launcher.chooseFolder()
                } label: {
                    Label(launcher.folder?.lastPathComponent ?? "Choose project", systemImage: "folder")
                        .lineLimit(1).frame(maxWidth: 190, alignment: .leading)
                }.buttonStyle(.plain).help(launcher.folder?.path ?? "Choose the folder the agent will work in")
                    .accessibilityIdentifier("agent.folder")
                Spacer(minLength: 0)
                Text("Interactive session in Terminal").font(.system(size: 10)).foregroundStyle(Theme.inkTertiary)
            }.font(Theme.Font.caption)
            HStack(alignment: .center, spacing: 10) {
                TextField("What should the agent do?", text: $launcher.prompt, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.Font.body).lineLimit(1...2)
                    .focused($focused).accessibilityIdentifier("agent.prompt")
                    .onSubmit { start() }
                Button(action: start) {
                    Label("Start", systemImage: "arrow.up")
                        .font(Theme.Font.caption).padding(.horizontal, 12).frame(height: 30)
                        .foregroundStyle(launcher.canLaunch ? Theme.background : Theme.inkTertiary)
                        .background(Capsule().fill(launcher.canLaunch ? Theme.accent : Theme.surfaceRaised))
                }.buttonStyle(PressableStyle()).disabled(!launcher.canLaunch)
                    .accessibilityIdentifier("agent.start")
            }
            Text(launcher.status).font(.system(size: 10)).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                .help(launcher.status).accessibilityIdentifier("agent.status")
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .onChange(of: focused) { _, active in if active { model.openByClick() } }
    }

    private func start() { model.openByClick(); launcher.launch() }
}
