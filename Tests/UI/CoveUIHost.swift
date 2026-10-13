import AppKit
import SwiftUI

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
            var data = try Data(contentsOf: Self.root.appendingPathComponent(file))
            // A fixture summary for every selectable fixture game. Scores/teams follow the selected row.
            if url.path.hasSuffix("summary"),
               let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "event" })?.value,
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
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Isolated UI test · recorded ESPN feeds").font(.caption)
                Spacer()
                Button("Show notch") { model.setExpanded(true) }
                Button("Quiet screenshot") {
                    model.addScreenshots([URL(fileURLWithPath: "/tmp/Cove UI Screenshot.png")])
                    print("CAPTURE tab=\(model.tab.rawValue) banner=\(model.banner != nil)")
                }
                Button("Offline") { UIFeed.offline.toggle(); model.sports.refresh() }
            }.padding(8)
            ExpandedView(model: model).frame(width: 660, height: 284).background(Color.black)
        }
        .environment(\.colorScheme, .dark)
    }
}

@MainActor final class UIHostDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var model: IslandModel!
    var notch: NotchWindowController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        setbuf(stdout, nil)
        let fixturePath = CommandLine.arguments.dropFirst().first { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
        UIFeed.root = URL(fileURLWithPath: fixturePath ?? Bundle.main.resourceURL!.appendingPathComponent("Fixtures").path)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [UIFeed.self]
        var config = CoveConfig()
        config.calendar = false; config.sounds = false; config.desktopAIActivity = false
        config.homeWidget = .sports; config.sportsLeague = .nba; config.sportsGameID = "401898402"
        model = IslandModel(config: config, sports: SportsMonitor(session: URLSession(configuration: sessionConfig)))
        model.applyConfig = { [weak self] config in
            guard let self else { return }
            self.model.config = config; self.model.sports.update(config: config)
            print("CONFIG widget=\(config.homeWidget.rawValue) league=\(config.sportsLeague.rawValue) game=\(config.sportsGameID ?? "none")")
        }
        model.ingest(CoveEvent(id: "web:chatgpt:ui:tab:1", title: "A long example title for checking truncation and controls", body: "This simulated reply checks the widget layout without reading any of your chats.", kind: "running", source: "chatgpt", phase: "Writing reply"))
        model.sports.start(config: config)
        model.setExpanded(true)
        notch = NotchWindowController(model: model)
        notch.panel.title = "Cove Test Notch"
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Cove UI Test"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: UIHostView(model: model))
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
