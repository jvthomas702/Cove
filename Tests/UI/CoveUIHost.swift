import AppKit
import SwiftUI
import Combine

final class UIFeed: URLProtocol {
    static var root = URL(fileURLWithPath: "")
    static var offline = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "site.api.espn.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let url = request.url!
        let league = url.path.contains("nba") ? "nba" : url.path.contains("college-football") ? "cfb" : "nfl"
        let file = league + (url.path.hasSuffix("summary") ? "-summary.json" : "-scoreboard.json")
        do {
            let eventID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "event" })?.value
            let rich = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appendingPathComponent(league + "-gamecast.json"))) as! [String: Any]
            let richHeader = rich["header"] as! [String: Any]
            var data = try Data(contentsOf: Self.root.appendingPathComponent(file))
            if url.path.hasSuffix("scoreboard"), var slate = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let competition = (richHeader["competitions"] as! [[String: Any]])[0]
                let event: [String: Any] = ["id": richHeader["id"]!, "date": competition["date"] ?? "", "competitions": [competition]]
                var events = slate["events"] as? [[String: Any]] ?? []
                events.append(event); slate["events"] = events
                data = try JSONSerialization.data(withJSONObject: slate)
            } else if eventID == richHeader["id"] as? String {
                data = try JSONSerialization.data(withJSONObject: rich)
            } else if let id = eventID,
               var summary = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let slate = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appendingPathComponent(league + "-scoreboard.json"))) as? [String: Any],
               let event = (slate["events"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }),
               var header = summary["header"] as? [String: Any] {
                header["id"] = id; header["competitions"] = event["competitions"]
                summary["header"] = header
                data = try JSONSerialization.data(withJSONObject: summary)
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

struct UIHostView: View {
    @ObservedObject var model: IslandModel
    var showNotch: () -> Void
    var hideNotch: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu("Fixtures") {
                    Button("Add AI task") {
                        model.ingest(CoveEvent(id: "web:claude:ui:tab:2", title: "Second AI task", body: "A second simulated response", kind: "running", source: "claude", phase: "Reasoning", url: "https://claude.ai/chat/ui"))
                    }
                    Button("Finish AI task") {
                        model.ingest(CoveEvent(id: "web:chatgpt:ui:tab:1", title: "Example reply", body: "Finished simulated reply", kind: "done", source: "chatgpt", silent: true))
                    }
                    Button("Follow slate") {
                        var config = model.config; config.sportsWatchedGames = model.sports.allGames.map(\.key)
                        model.applyConfig?(config)
                    }
                    Button("Favorite Miami Heat") { model.toggleFavorite("14", league: .nba) }
                }.accessibilityIdentifier("ui.fixtures")
                // Left of the island, so the real notch never covers it.
                Button("Offline") { UIFeed.offline.toggle(); model.sports.refresh() }
                Spacer()
                Button("Show notch", action: showNotch)
                Button("Hide notch", action: hideNotch)
                Button("Quiet screenshot") {
                    let shot = FileManager.default.temporaryDirectory.appendingPathComponent("Cove UI Screenshot.png")
                    if let logo = Bundle.main.url(forResource: "nba-1", withExtension: "png", subdirectory: "TeamLogos"),
                       let data = try? Data(contentsOf: logo) { try? data.write(to: shot) }
                    model.addScreenshots([shot])
                    print("CAPTURE tab=\(model.tab.rawValue) banner=\(model.banner != nil)")
                }
                Button("Delete source") {
                    try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Cove UI Screenshot.png"))
                }
            }.controlSize(.small).font(.system(size: 10.5)).padding(8)
            ExpandedView(model: model).frame(width: model.size(for: .expanded).width, height: model.size(for: .expanded).height).background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, model.config.islandTheme.colorScheme)
    }
}

@MainActor final class UIHostDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var model: IslandModel!
    var notch: NotchWindowController!
    var settings: SettingsWindowController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        setbuf(stdout, nil)
        let fixturePath = CommandLine.arguments.dropFirst().first { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
        UIFeed.root = URL(fileURLWithPath: fixturePath ?? Bundle.main.resourceURL!.appendingPathComponent("Fixtures").path)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [UIFeed.self]
        var config = CoveConfig()
        config.calendar = false; config.sounds = false; config.desktopAIActivity = false
        config.homeWidget = .sports; config.sportsLeague = .nba; config.sportsGameID = "401810946"
        NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("--light-system") ? .aqua : .darkAqua)
        let shelfDefaults = UserDefaults(suiteName: "app.cove.ui-test.shelf")!
        if !CommandLine.arguments.contains("--preserve-shelf") {
            ShelfStore(defaults: shelfDefaults, root: FileManager.default.temporaryDirectory.appendingPathComponent("cove-ui-shelf")).clear()
        }
        model = IslandModel(config: config, sports: SportsMonitor(session: URLSession(configuration: sessionConfig)), shelfStore: ShelfStore(defaults: shelfDefaults, root: FileManager.default.temporaryDirectory.appendingPathComponent("cove-ui-shelf")))
        model.agentLauncher.folder = UIFeed.root
        model.agentLauncher.resolveExecutable = { _ in URL(fileURLWithPath: "/usr/bin/true") }
        model.agentLauncher.openCommand = { url, completion in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            completion(nil)
        }
        model.applyConfig = { [weak self] config in
            guard let self else { return }
            self.model.config = config; self.model.sports.update(config: config)
            print("CONFIG widget=\(config.homeWidget.rawValue) league=\(config.sportsLeague.rawValue) game=\(config.sportsGameID ?? "none")")
        }
        if !CommandLine.arguments.contains("--no-ai") {
            model.ingest(CoveEvent(id: "web:chatgpt:ui:tab:1", title: "A long example title for checking truncation and controls", body: "This simulated reply checks the widget layout without reading any of your chats.", kind: "running", source: "chatgpt", phase: "Writing reply"))
        }
        model.codexChats.configureForTesting(chats: [
            CodexChat(id: "11111111-1111-4111-8111-111111111111", title: "Cove updates", folder: "/tmp/Cove"),
            CodexChat(id: "22222222-2222-4222-8222-222222222222", title: "Other project", folder: "/tmp/Other")
        ]) { _, _, _, completion in completion(.success([:])) }
        model.openSettings = { [weak self] pane in
            guard let self else { return }
            if self.settings == nil { self.settings = SettingsWindowController(controller: SettingsController(model: self.model)) }
            self.settings?.show(pane: pane)
        }
        model.sports.start(config: config)
        model.setExpanded(true)
        notch = NotchWindowController(model: model)
        notch.panel.title = "Cove Test Notch"
        notch.panel.orderOut(nil)
        let initialSize = model.size(for: .expanded)
        // Keep the fixture toolbar at a stable origin while the real island changes height,
        // and wide enough for every fixture button now that the island itself is narrow.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(initialSize.width, 760), height: 550), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Cove UI Test"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: UIHostView(model: model, showNotch: { [weak self] in
            guard let self else { return }
            self.window.setFrameOrigin(NSPoint(x: 80, y: 30))
            self.model.tab = .home
            self.model.setExpanded(true)
            self.notch.panel.orderFrontRegardless()
        }, hideNotch: { [weak self] in self?.notch.panel.orderOut(nil) }))
        host.sizingOptions = []
        window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct CoveUIHost {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = UIHostDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
