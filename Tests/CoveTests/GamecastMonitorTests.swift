import Foundation
import XCTest
@testable import Cove

private final class GamecastProtocol: URLProtocol {
    static let lock = NSLock()
    static var root: URL!
    static var fail = false
    static var boardDelay: TimeInterval = 0
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "site.api.espn.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let delay = Self.lock.withLock { request.url!.path.hasSuffix("scoreboard") ? Self.boardDelay : 0 }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            let state = Self.lock.withLock { (cancelled, Self.fail, Self.root!) }
            guard !state.0 else { return }
            if state.1 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
            let url = request.url!
            let league = url.path.contains("nba") ? "nba" : "nfl"
            let name = league + (url.path.hasSuffix("summary") ? "-gamecast.json" : "-scoreboard.json")
            do {
                let data = try Data(contentsOf: state.2.appendingPathComponent(name))
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { Self.lock.withLock { cancelled = true } }
}

@MainActor final class GamecastMonitorTests: XCTestCase {
    private func idle(_ monitor: SportsMonitor) async throws {
        for _ in 0..<150 {
            if !monitor.loading { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Sports request did not finish")
        throw URLError(.timedOut)
    }
    func testDetailDoesNotWaitForSlowSlateAndOfflinePreservesRichData() async throws {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        GamecastProtocol.lock.withLock {
            GamecastProtocol.root = root
            GamecastProtocol.fail = false; GamecastProtocol.boardDelay = 1.5
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GamecastProtocol.self]
        let session = URLSession(configuration: configuration)
        let monitor = SportsMonitor(session: session)
        var config = CoveConfig(); config.sportsLeague = .nba; config.sportsGameID = "401810946"
        monitor.start(config: config)
        defer { monitor.stop(); session.invalidateAndCancel() }
        for _ in 0..<50 {
            if monitor.updatedAt != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(monitor.plays.count, 475)
        XCTAssertTrue(monitor.loading) // The scoreboard is still waiting; detail is already visible.
        XCTAssertFalse(monitor.stats.isEmpty)
        try await idle(monitor)
        GamecastProtocol.lock.withLock { GamecastProtocol.boardDelay = 0 }
        config.sportsLeague = .nfl; config.sportsGameID = "401772918"
        monitor.update(config: config)
        try await idle(monitor)
        let plays = monitor.plays, drives = monitor.drives, stats = monitor.stats, updated = monitor.updatedAt
        XCTAssertEqual(plays.count, 197); XCTAssertFalse(drives.isEmpty)
        GamecastProtocol.lock.withLock { GamecastProtocol.fail = true }
        monitor.refresh()
        try await idle(monitor)
        XCTAssertNotNil(monitor.detailError)
        XCTAssertEqual(monitor.plays, plays); XCTAssertEqual(monitor.drives, drives)
        XCTAssertEqual(monitor.stats, stats); XCTAssertEqual(monitor.updatedAt, updated)
    }
}
