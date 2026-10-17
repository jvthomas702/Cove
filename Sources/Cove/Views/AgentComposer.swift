import SwiftUI

struct AgentComposer: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var launcher: AgentLauncher
    @ObservedObject var chats: CodexChats
    @FocusState private var focused: Bool

    init(model: IslandModel) {
        self.model = model
        self.launcher = model.agentLauncher
        self.chats = model.codexChats
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Picker("Send to", selection: $model.composeNewTask) {
                    Text("Existing chat").tag(false)
                    Text("New task").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220).accessibilityIdentifier("agent.destination")
                Spacer()
                if !model.composeNewTask {
                    Button("Open chat") { model.openByClick(); chats.openSelected() }
                        .buttonStyle(PillButtonStyle()).disabled(chats.selectedChat == nil).accessibilityIdentifier("chat.open")
                    Button { chats.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(PillButtonStyle(tint: Theme.inkSecondary)).help("Refresh chats").accessibilityIdentifier("chat.refresh")
                }
            }.font(Theme.Font.caption)
            if model.composeNewTask { newTaskComposer } else { chatComposer }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .onChange(of: focused) { _, active in if active { model.openByClick() } }
    }

    private var newTaskComposer: some View {
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
                Button(action: start) { Label("Start", systemImage: "arrow.up") }
                    .buttonStyle(PillButtonStyle(prominent: true)).disabled(!launcher.canLaunch)
                    .accessibilityIdentifier("agent.start")
            }
            Text(launcher.status).font(.system(size: 10)).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                .help(launcher.status).accessibilityIdentifier("agent.status")
        }
    }

    private var chatComposer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Chat", selection: $chats.selectedID) {
                if chats.chats.isEmpty { Text("Open Codex to load chats").tag("") }
                if !chats.selectedID.isEmpty && chats.selectedChat == nil { Text("Selected chat unavailable").tag(chats.selectedID) }
                ForEach(chats.chats) { chat in Text(chat.title).tag(chat.id) }
            }.labelsHidden().accessibilityIdentifier("chat.choice")
            HStack(spacing: 10) {
                TextField("Message the selected chat…", text: $chats.prompt, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.Font.body).lineLimit(1...2)
                    .focused($focused).accessibilityIdentifier("chat.prompt")
                    .onSubmit { send() }
                Button(action: send) { Label(chats.sending ? "Sending…" : "Send", systemImage: "arrow.up") }
                    .buttonStyle(PillButtonStyle(prominent: true)).disabled(!chats.canSend).accessibilityIdentifier("chat.send")
            }
            Text(chats.status).font(.system(size: 10)).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                .help(chats.status).accessibilityIdentifier("chat.status")
        }
    }

    private func send() { model.openByClick(); chats.send() }
    private func start() { model.openByClick(); launcher.launch() }
}
