import Foundation
import SQLite3
import os

private let log = Logger(subsystem: "dev.barkeep.mac", category: "notifications")

struct ForwardedNotification {
    let bundleID: String
    let title: String
    let body: String
}

/// Polls the macOS Notification Center database for newly delivered
/// notifications. Requires Full Disk Access — the DB lives in a
/// TCC-protected group container on modern macOS.
final class NotificationWatcher: @unchecked Sendable {
    enum Status: Equatable {
        case stopped
        case watching
        case noAccess
        case error(String)
    }

    var onNotification: (@Sendable (ForwardedNotification) -> Void)?
    var onStatusChange: (@Sendable (Status) -> Void)?

    private static let candidatePaths: [String] = [
        NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db",
        darwinUserDir().map { $0 + "com.apple.notificationcenter/db2/db" },
    ].compactMap { $0 }

    private let queue = DispatchQueue(label: "busybar.notificationwatcher")
    private var timer: DispatchSourceTimer?
    private var db: OpaquePointer?
    /// UUIDs of notifications already handled. rec_ids get reused by
    /// Notification Center after deletions, so they can't be a watermark.
    private var seenUUIDs: Set<String> = []
    private var primed = false
    private(set) var status: Status = .stopped {
        didSet {
            if status != oldValue { onStatusChange?(status) }
        }
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 2.0)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            if let db { sqlite3_close_v2(db) }
            db = nil
            seenUUIDs.removeAll()
            primed = false
            status = .stopped
        }
    }

    private func poll() {
        guard ensureOpen() else { return }
        guard let db else { return }

        let sql = """
        SELECT r.rec_id, COALESCE(a.identifier, ''), r.uuid, r.data
        FROM record r LEFT JOIN app a ON a.app_id = r.app_id
        ORDER BY r.rec_id
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            status = .error(String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let recID = sqlite3_column_int64(stmt, 0)
            let bundleID = String(cString: sqlite3_column_text(stmt, 1))
            let key = Self.uuidKey(stmt, column: 2) ?? "rec-\(recID)-\(bundleID)"
            guard !seenUUIDs.contains(key) else { continue }
            seenUUIDs.insert(key)

            // First poll: mark history as seen, only forward what arrives later.
            guard primed else { continue }

            guard let blob = sqlite3_column_blob(stmt, 3) else {
                log.warning("rec \(recID) from \(bundleID, privacy: .public): empty data blob")
                continue
            }
            let size = Int(sqlite3_column_bytes(stmt, 3))
            let data = Data(bytes: blob, count: size)
            if let note = Self.decode(data, bundleID: bundleID) {
                log.info("rec \(recID) from \(bundleID, privacy: .public): title \(note.title.count) chars, body \(note.body.count) chars")
                onNotification?(note)
            } else {
                log.warning("rec \(recID) from \(bundleID, privacy: .public): could not decode plist (\(size) bytes)")
            }
        }
        if !primed {
            primed = true
            log.info("watching; primed with \(self.seenUUIDs.count) existing notifications")
        }
        status = .watching
    }

    private static func uuidKey(_ stmt: OpaquePointer?, column: Int32) -> String? {
        switch sqlite3_column_type(stmt, column) {
        case SQLITE_BLOB:
            guard let blob = sqlite3_column_blob(stmt, column) else { return nil }
            let size = Int(sqlite3_column_bytes(stmt, column))
            return Data(bytes: blob, count: size).map { String(format: "%02x", $0) }.joined()
        case SQLITE_TEXT:
            return String(cString: sqlite3_column_text(stmt, column))
        default:
            return nil
        }
    }

    private func ensureOpen() -> Bool {
        if db != nil { return true }
        for path in Self.candidatePaths where FileManager.default.fileExists(atPath: path) || path.contains("usernoted") {
            var handle: OpaquePointer?
            let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
            // sqlite defers real I/O; force a read so TCC denial surfaces here.
            if rc == SQLITE_OK, let opened = handle {
                var stmt: OpaquePointer?
                let probe = sqlite3_prepare_v2(opened, "SELECT name FROM sqlite_master WHERE type='table'", -1, &stmt, nil)
                var tables: [String] = []
                if probe == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        tables.append(String(cString: sqlite3_column_text(stmt, 0)))
                    }
                }
                sqlite3_finalize(stmt)
                if probe == SQLITE_OK, !tables.isEmpty {
                    log.info("opened \(path, privacy: .public); tables: \(tables.joined(separator: ","), privacy: .public)")
                    db = opened
                    logRecentSources()
                    return true
                }
                log.warning("probe failed for \(path, privacy: .public): rc=\(probe) \(String(cString: sqlite3_errmsg(opened)), privacy: .public)")
                sqlite3_close_v2(opened)
            } else {
                log.warning("open failed for \(path, privacy: .public): rc=\(rc)")
                if let handle { sqlite3_close_v2(handle) }
            }
        }
        status = .noAccess
        return false
    }

    /// Logs which apps produced the most recent notifications — bundle IDs
    /// only, no content. Helps users build the forwarding filter.
    private func logRecentSources() {
        guard let db else { return }
        let sql = """
        SELECT r.rec_id, COALESCE(a.identifier, '?')
        FROM record r LEFT JOIN app a ON a.app_id = r.app_id
        ORDER BY r.rec_id DESC LIMIT 15
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        var sources: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let recID = sqlite3_column_int64(stmt, 0)
            let identifier = String(cString: sqlite3_column_text(stmt, 1))
            sources.append("\(recID)=\(identifier)")
        }
        log.info("recent notification sources: \(sources.joined(separator: " "), privacy: .public)")
    }

    /// Notification records are binary plists; title/subtitle/body live under "req".
    private static func decode(_ data: Data, bundleID: String) -> ForwardedNotification? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any] else { return nil }
        let req = root["req"] as? [String: Any] ?? [:]
        let title = (req["titl"] as? String) ?? ""
        let subtitle = (req["subt"] as? String) ?? ""
        let body = (req["body"] as? String) ?? ""
        let app = bundleID.isEmpty ? (root["app"] as? String ?? "") : bundleID
        guard !(title.isEmpty && body.isEmpty) else { return nil }
        let combinedBody = [subtitle, body].filter { !$0.isEmpty }.joined(separator: " — ")
        return ForwardedNotification(bundleID: app, title: title, body: combinedBody)
    }

    private static func darwinUserDir() -> String? {
        let length = confstr(_CS_DARWIN_USER_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        confstr(_CS_DARWIN_USER_DIR, &buffer, length)
        return String(cString: buffer)
    }
}
