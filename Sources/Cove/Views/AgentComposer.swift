import AppKit
import SwiftUI

struct AgentComposer: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var launcher: AgentLauncher
    @ObservedObject var chats: CodexChats
    @ObservedObject var cloud: CloudAgents
    @FocusState private var focused: Bool
    @State private var addingLink = false

    init(model: IslandModel) {
        self.model = model
        self.launcher = model.agentLauncher
        self.chats = model.codexChats
        self.cloud = model.cloudAgents
    }

    private var status: String {
        switch model.composeTarget {
        case .chat: return chats.status
        case .cloud: return cloud.status
        case .newTask: return launcher.status
        }
    }

    private var statusID: String {
        switch model.composeTarget {
        case .chat: return "chat.status"
        case .cloud: return "cloud.status"
        case .newTask: return "agent.status"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Send to", selection: $model.composeTarget) {
                    ForEach(IslandModel.ComposeTarget.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 210).accessibilityIdentifier("agent.destination")
                Text(status)
                    .font(.system(size: 10, design: Theme.isTerminal ? .monospaced : .default))
                    .foregroundStyle(Theme.inkTertiary).lineLimit(1).truncationMode(.middle)
                    .help(status)
                    .accessibilityIdentifier(statusID)
                Spacer(minLength: 0)
                if model.composeTarget == .cloud {
                    IconButton(systemImage: addingLink ? "xmark" : "link.badge.plus", size: 11, hit: 24) {
                        model.openByClick(); addingLink.toggle()
                    }
                    .help(addingLink ? "Cancel" : "Add a cloud session by its claude.ai/code link")
                    .accessibilityLabel(addingLink ? "Cancel adding a session" : "Add cloud session")
                    .accessibilityIdentifier("cloud.add")
                    IconButton(systemImage: "arrow.up.forward.app", size: 11, hit: 24) {
                        if let url = cloud.selected?.url { NSWorkspace.shared.open(url) }
                    }
                    .help("Open this session on claude.ai").accessibilityLabel("Open session on claude.ai")
                    .disabled(cloud.selected == nil).accessibilityIdentifier("cloud.open")
                }
                if model.composeTarget == .chat {
                    IconButton(systemImage: "arrow.up.forward.app", size: 11, hit: 24) { model.openByClick(); chats.openSelected() }
                        .help("Open this chat in Codex").accessibilityLabel("Open chat")
                        .disabled(chats.selectedChat == nil).accessibilityIdentifier("chat.open")
                    IconButton(systemImage: "arrow.clockwise", size: 11, hit: 24) { chats.refresh() }
                        .help("Refresh chats").accessibilityLabel("Refresh chats").accessibilityIdentifier("chat.refresh")
                }
            }
            switch model.composeTarget {
            case .chat: chatComposer
            case .cloud: if addingLink || cloud.sessions.isEmpty { cloudLinkField } else { cloudComposer }
            case .newTask: newTaskComposer
            }
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

    // MARK: Cloud sessions

    private var cloudComposer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("Session", selection: $cloud.selectedID) {
                    ForEach(cloud.sessions) { session in Text(shortTitle(session.title)).tag(session.id) }
                }.labelsHidden().frame(maxWidth: 170).accessibilityIdentifier("cloud.choice")
                    .help(cloud.selected.map { [$0.title, $0.repo].compactMap { $0 }.joined(separator: " · ") } ?? "Choose a cloud session")
                    .contextMenu {
                        if let selected = cloud.selected {
                            Button("Forget \(shortTitle(selected.title))") { cloud.remove(selected.id) }
                        }
                    }
                promptGlyph("›")
                TextField("Message the cloud session…", text: $cloud.prompt, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.isTerminal ? Theme.Font.code : Theme.Font.body).lineLimit(1...2)
                    .focused($focused).accessibilityIdentifier("cloud.prompt")
                    .onSubmit { sendCloud() }
                Button(action: sendCloud) { Label(cloud.sending ? "Sending…" : "Send", systemImage: "arrow.up") }
                    .buttonStyle(PillButtonStyle(prominent: true)).disabled(!cloud.canSend).accessibilityIdentifier("cloud.send")
            }
            if let last = cloud.selectedMessages.last {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 8, weight: .bold))
                    Text("You: \(last.text.oneLine(max: 80))").lineLimit(1)
                    Text(last.sentAt.formatted(.relative(presentation: .named)))
                }
                .font(.system(size: 9.5)).foregroundStyle(Theme.inkTertiary)
                .help(last.text)
                .accessibilityIdentifier("cloud.lastSent")
            }
        }.font(Theme.Font.caption)
    }

    private var cloudLinkField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
            TextField("Paste a claude.ai/code session link", text: $cloud.linkDraft)
                .textFieldStyle(.plain).font(Theme.isTerminal ? Theme.Font.code : Theme.Font.body)
                .focused($focused).accessibilityIdentifier("cloud.link")
                .onSubmit { addLink() }
            Button(action: addLink) { Label("Add", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(CloudAgents.sessionID(in: cloud.linkDraft) == nil)
                .accessibilityIdentifier("cloud.addLink")
        }.font(Theme.Font.caption)
    }

    private func addLink() {
        model.openByClick()
        if cloud.addFromDraft() { addingLink = false }
    }

    private func sendCloud() { model.openByClick(); cloud.send() }
    private func send() { model.openByClick(); chats.send() }
    private func start() { model.openByClick(); launcher.launch() }
}
