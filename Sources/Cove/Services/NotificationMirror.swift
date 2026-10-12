import Foundation
import SQLite3

/// Mirrors macOS notifications into the island by watching Notification Center's own database.
///
/// macOS has no public API for reading other apps' notifications, so this reads the usernoted
/// SQLite store (read-only). It needs Full Disk Access, and because the schema is private it may need
/// an update after a major macOS release — if it fails, Cove simply stops mirroring.
final class NotificationMirror {
    struct Item {
        let appID: String
        let title: String
        let subtitle: String
        let body: String
    }

    var onItems: (@MainActor ([Item]) -> Void)?
    var onAccessDenied: (@MainActor () -> Void)?

    private let queue = DispatchQueue(label: "cove.notifications", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var db: OpaquePointer?
    private var lastID: Int64 = 0
    private var reportedDenied = false
    private var failures = 0

    static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [home + "/Library/Group Containers/group.com.apple.usernoted/db2/db"] // macOS 15+
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 {
            paths.append(String(cString: buffer) + "com.apple.notificationcenter/db2/db") // macOS 14
        }
        return paths
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(2), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { [weak self] in self?.close() }
    }

    private func openIfNeeded() -> Bool {
        if db != nil { return true }
        for path in Self.candidatePaths {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
                if let handle { sqlite3_close(handle) }
                continue
            }
            if let maxID = scalar(handle, "SELECT IFNULL(MAX(rec_id), 0) FROM record") {
                db = handle
                lastID = maxID // only mirror notifications that arrive from now on
                return true
            }
            sqlite3_close(handle)
        }
        if !reportedDenied {
            reportedDenied = true
            Task { @MainActor [weak self] in self?.onAccessDenied?() }
        }
        return false
    }

    private func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    private func scalar(_ handle: OpaquePointer, _ sql: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func poll() {
        guard openIfNeeded(), let db else { return }
        let sql = """
        SELECT r.rec_id, a.identifier, r.data
        FROM record r JOIN app a ON a.app_id = r.app_id
        WHERE r.rec_id > ? ORDER BY r.rec_id LIMIT 25
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            failures += 1
            if failures > 5 { close(); failures = 0 } // reopen on the next tick (e.g. after a DB rotation)
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, lastID)

        var items: [Item] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            lastID = max(lastID, sqlite3_column_int64(stmt, 0))
            guard let idText = sqlite3_column_text(stmt, 1) else { continue }
            let appID = String(cString: idText)
            let length = Int(sqlite3_column_bytes(stmt, 2))
            guard length > 0, let blob = sqlite3_column_blob(stmt, 2) else { continue }
            if let item = Self.decode(Data(bytes: blob, count: length), appID: appID) {
                items.append(item)
            }
        }
        failures = 0
        if !items.isEmpty {
            let delivered = items
            Task { @MainActor [weak self] in self?.onItems?(delivered) }
        }
    }

    /// Each record's `data` column is a binary plist; the visible text lives under "req".
    static func decode(_ data: Data, appID: String) -> Item? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let request = plist["req"] as? [String: Any] else { return nil }
        let title = request["titl"] as? String ?? ""
        let subtitle = request["subt"] as? String ?? ""
        let body = request["body"] as? String ?? ""
        guard !(title.isEmpty && body.isEmpty) else { return nil }
        let app = plist["app"] as? String ?? appID
        return Item(appID: app, title: title, subtitle: subtitle, body: body)
    }
}
