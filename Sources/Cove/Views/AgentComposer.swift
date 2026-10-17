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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Send to", selection: $model.composeNewTask) {
                    Text("Chat").tag(false)
                    Text("New task").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 150).accessibilityIdentifier("agent.destination")
                Text(model.composeNewTask ? launcher.status : chats.status)
                    .font(.system(size: 10, design: Theme.isTerminal ? .monospaced : .default))
                    .foregroundStyle(Theme.inkTertiary).lineLimit(1).truncationMode(.middle)
                    .help(model.composeNewTask ? launcher.status : chats.status)
                    .accessibilityIdentifier(model.composeNewTask ? "agent.status" : "chat.status")
                Spacer(minLength: 0)
                if !model.composeNewTask {
                    IconButton(systemImage: "arrow.up.forward.app", size: 11, hit: 24) { model.openByClick(); chats.openSelected() }
                        .help("Open this chat in Codex").accessibilityLabel("Open chat")
                        .disabled(chats.selectedChat == nil).accessibilityIdentifier("chat.open")
                    IconButton(systemImage: "arrow.clockwise", size: 11, hit: 24) { chats.refresh() }
                        .help("Refresh chats").accessibilityLabel("Refresh chats").accessibilityIdentifier("chat.refresh")
                }
            }
            if model.composeNewTask { newTaskComposer } else { chatComposer }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
        .overlay { if Theme.isTerminal { RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 1) } }
        .onChange(of: focused) { _, active in if active { model.openByClick() } }
    }

    /// `$` / `›` before the field in the terminal look, nothing otherwise.
    @ViewBuilder private func promptGlyph(_ glyph: String) -> some View {
        if Theme.isTerminal { Text(glyph).font(Theme.Font.code.weight(.bold)).foregroundStyle(Theme.accent) }
    }

    private var newTaskComposer: some View {
        HStack(spacing: 8) {
            Picker("Agent", selection: $launcher.agent) {
                ForEach(LaunchAgent.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().fixedSize().accessibilityIdentifier("agent.choice")
            Button {
                model.openByClick(); launcher.chooseFolder()
            } label: {
                Label(launcher.folder?.lastPathComponent ?? "Project", systemImage: "folder")
                    .frame(maxWidth: 110, alignment: .leading)
            }.buttonStyle(PillButtonStyle())
                .help((launcher.folder?.path ?? "Choose the folder the agent will work in") + " · opens an interactive session in Terminal")
                .accessibilityIdentifier("agent.folder")
            promptGlyph("$")
            TextField("What should the agent do?", text: $launcher.prompt, axis: .vertical)
                .textFieldStyle(.plain).font(Theme.isTerminal ? Theme.Font.code : Theme.Font.body).lineLimit(1...2)
                .focused($focused).accessibilityIdentifier("agent.prompt")
                .onSubmit { start() }
            Button(action: start) { Label("Start", systemImage: "arrow.up") }
                .buttonStyle(PillButtonStyle(prominent: true)).disabled(!launcher.canLaunch)
                .accessibilityIdentifier("agent.start")
        }.font(Theme.Font.caption)
    }

    /// Recent chats only, so the menu stays short; the chosen chat is kept even if it's older.
    private var chatChoices: [CodexChat] {
        var recent = Array(chats.chats.prefix(10))
        if let selected = chats.selectedChat, !recent.contains(selected) { recent.append(selected) }
        return recent
    }

    private func shortTitle(_ title: String) -> String {
        title.count > 34 ? String(title.prefix(33)) + "…" : title
    }

    private var chatComposer: some View {
        HStack(spacing: 8) {
            Picker("Chat", selection: $chats.selectedID) {
                if chats.chats.isEmpty { Text("Open Codex to load chats").tag("") }
                if !chats.selectedID.isEmpty && chats.selectedChat == nil { Text("Chat unavailable").tag(chats.selectedID) }
                ForEach(chatChoices) { chat in Text(shortTitle(chat.title)).tag(chat.id) }
            }.labelsHidden().frame(maxWidth: 160).accessibilityIdentifier("chat.choice")
                .help(chats.selectedChat.map { "\($0.title) · \($0.folder)" } ?? "Choose a Codex chat")
            promptGlyph("›")
            TextField("Message the selected chat…", text: $chats.prompt, axis: .vertical)
                .textFieldStyle(.plain).font(Theme.isTerminal ? Theme.Font.code : Theme.Font.body).lineLimit(1...2)
                .focused($focused).accessibilityIdentifier("chat.prompt")
                .onSubmit { send() }
            Button(action: send) { Label(chats.sending ? "Sending…" : "Send", systemImage: "arrow.up") }
                .buttonStyle(PillButtonStyle(prominent: true)).disabled(!chats.canSend).accessibilityIdentifier("chat.send")
        }.font(Theme.Font.caption)
    }

    private func send() { model.openByClick(); chats.send() }
    private func start() { model.openByClick(); launcher.launch() }
}
